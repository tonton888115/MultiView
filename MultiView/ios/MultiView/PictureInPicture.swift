import Accelerate
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import UIKit

// ピクチャ・イン・ピクチャ(PiP)。各セルの PiP ボタンでその配信を PiP にし、PiP 上にもコメントを
// 流す(ニコ生公式アプリと同じ体験)。
//
// 方式(ニコ生公式と同じ iOS 15+ の公式 API): 再生中の AVPlayer から AVPlayerItemVideoOutput で
// 映像フレームを受け取り、そのフレームへコメントを直接描き込んでから AVSampleBufferDisplayLayer へ
// 流し、そのレイヤーを PiP の中身にする(AVPictureInPictureController.ContentSource)。
// PiP に映るのは自分で作ったフレームそのものなので、PiP の窓の上に何かを重ねる方式(非公開の窓頼み・
// iOS によっては表示されない)と違い、確実にコメントが映る。
// フレームは 60fps の一定間隔で、表示時刻を付けて渡す(なめらかに流れる)。出力は PiP の窓の実ピクセルの
// 大きさで作り、コメントも等倍で描く(文字がくっきり)。バックグラウンドでは GPU を使えないため CPU で描く。
// Amazon IVS(Kick/Twitch)からは映像フレームを取り出せないので、PiP の間だけ AVPlayer 再生へ
// 切り替える(閉じたら IVS へ戻す)。
//
// ニコ生公式アプリ(6.19.0)を解析して確認した対応関係: 公式も同じ構成
// (AVPlayerItemVideoOutput → コメント合成 → CMSampleBuffer → AVSampleBufferDisplayLayer →
// AVPictureInPictureController.ContentSource)。違いは合成の手段だけ(公式は Metal、こちらは CPU)。
// コメントの大きさ・流れ方・段の決め方は、タイルの弾幕と共通のエンジン(DanmakuEngine.swift)で
// 公式と同じ規則にしてある。

/// PiP にできるプレイヤー(各ネイティブプレイヤーが準拠)。
protocol PictureInPictureCapable: AnyObject {
  /// PiP の映像フレームを取り出す AVPlayer。読み込み中・Web表示中は nil。
  /// Amazon IVS 再生中は映像フレームを取り出せないため、AVPlayer 再生へ切り替えてから返す。
  func preparePictureInPicturePlayer() -> AVPlayer?
  /// PiP を閉じた(IVS 再生へ戻す等)。
  func pictureInPictureDidEnd()
  /// このプレイヤーのコメント(弾幕)が流れるビュー。PiP 中はここへ流れたコメントを PiP にも描く。
  var pictureInPictureDanmakuView: UIView { get }
}

extension PictureInPictureCapable {
  func pictureInPictureDidEnd() {}
}

extension Notification.Name {
  /// PiP の対象配信が変わった(開始要求・開始・終了)。セルのボタン表示を更新する。
  static let multiViewPictureInPictureChanged = Notification.Name("MultiViewPictureInPictureChanged")
}

final class PictureInPictureCoordinator: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
  static let shared = PictureInPictureCoordinator()

  /// PiP 表示中(開始処理中を含む)の配信ID。同時に PiP にできるのは 1 配信だけ。
  private(set) var activeStreamID: String?
  private var activeLabel = ""
  private var controller: AVPictureInPictureController?
  private var displayView: PictureInPictureDisplayView?
  private var renderer: PictureInPictureFrameRenderer?
  private weak var source: PictureInPictureCapable?
  private weak var sourceDanmakuView: UIView?
  private weak var player: AVPlayer?
  private var possibleObservation: NSKeyValueObservation?
  private var playerStatusObservation: NSKeyValueObservation?
  private var startTimeoutWork: DispatchWorkItem?
  private var onMessage: ((String) -> Void)?
  // 開始/終了のアニメーション中。この間のボタン操作は無視する(連打で窓が取り残されないように)。
  private var transitionInProgress = false
  // 開始アニメーション中に閉じる必要が生じた(配信の削除など)。開始し終えた直後に閉じる。
  private var closeAfterStart = false
  // 別の配信を PiP 中に押された場合、今の PiP が閉じ終わってから開始する。
  private var pendingStart: (() -> Void)?
  private var pendingStartFallbackWork: DispatchWorkItem?
  // PiP の一時停止ボタンで止めた。ライブの停止監視(StallWatchdog)に押し直させない。
  private var pausedByUser = false

  private override init() {
    super.init()
  }

  func isActive(streamID: String) -> Bool {
    activeStreamID == streamID
  }

  /// StallWatchdog 用: この AVPlayer は PiP の一時停止ボタンで意図的に止められているか。
  func isPausedFromPictureInPicture(_ player: AVPlayer) -> Bool {
    pausedByUser && player === self.player
  }

  /// セルの PiP ボタン。その配信が PiP 中なら閉じ、そうでなければその配信を PiP にする。
  /// host: PiP 用の映像レイヤーを置くビュー(セル。開始/復帰のアニメーションはここから)。
  func toggle(
    streamID: String,
    label: String,
    source: PictureInPictureCapable?,
    host: UIView,
    onMessage: @escaping (String) -> Void
  ) {
    guard !transitionInProgress, pendingStart == nil else { return }
    if activeStreamID == streamID {
      PlaybackDiagnostics.log("PiP: \(label) 終了要求")
      stop()
      return
    }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      onMessage("この端末はピクチャ・イン・ピクチャに対応していません")
      return
    }
    guard let source else {
      onMessage("この配信はピクチャ・イン・ピクチャに対応していません")
      return
    }
    if let current = controller, current.isPictureInPictureActive {
      // 同時に出せる PiP は 1 つ。今の PiP を閉じ、閉じ終わってから切り替える。
      pendingStart = { [weak self, weak source, weak host] in
        guard let self, let source, let host else { return }
        self.start(streamID: streamID, label: label, source: source, host: host, onMessage: onMessage)
      }
      schedulePendingStartFallback()
      transitionInProgress = true
      current.stopPictureInPicture()
      return
    }
    start(streamID: streamID, label: label, source: source, host: host, onMessage: onMessage)
  }

  /// その配信のプレイヤーを止める時(配信の削除・作り直し)。PiP 中なら閉じる。
  func stopIfActive(streamID: String) {
    guard activeStreamID == streamID else { return }
    stop()
  }

  func stop() {
    guard let controller else { return }
    if controller.isPictureInPictureActive {
      transitionInProgress = true
      controller.stopPictureInPicture()
    } else if transitionInProgress {
      // 開始アニメーション中の停止要求は無視されうるので、開始し終えた直後に閉じる。
      closeAfterStart = true
    } else {
      teardown(notify: true)
    }
  }

  /// NativeDanmakuRenderer.emit から呼ばれる。PiP 中の配信のコメントなら PiP の映像にも描く。
  func mirrorDanmaku(tokens: [NativeDanmakuToken], from root: UIView, settings: AppSettings, style: DanmakuStyle) {
    guard let renderer, root === sourceDanmakuView else { return }
    renderer.addComment(tokens: tokens, settings: settings, style: style)
  }

  private func start(
    streamID: String,
    label: String,
    source: PictureInPictureCapable,
    host: UIView,
    onMessage: @escaping (String) -> Void
  ) {
    teardown(notify: false)
    guard let player = source.preparePictureInPicturePlayer() else {
      postChange()
      onMessage("映像の読み込み中か、この表示ではPiPにできません")
      return
    }
    // PiP の中身になる映像レイヤー。セルの一番奥(映像の裏)に置くので見た目は変わらない。
    let view = PictureInPictureDisplayView(frame: host.bounds)
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    host.insertSubview(view, at: 0)
    let renderer = PictureInPictureFrameRenderer(
      displayLayer: view.displayLayer,
      label: label,
      screenScale: host.traitCollection.displayScale
    )
    renderer.attach(player: player)
    renderer.start()

    let contentSource = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: view.displayLayer,
      playbackDelegate: self
    )
    let pip = AVPictureInPictureController(contentSource: contentSource)
    pip.delegate = self
    // 複数の配信を並べるアプリなので、アプリを離れた時に勝手に PiP へ入れない(ボタンでのみ開始)。
    pip.canStartPictureInPictureAutomaticallyFromInline = false

    controller = pip
    displayView = view
    self.renderer = renderer
    self.source = source
    self.player = player
    sourceDanmakuView = source.pictureInPictureDanmakuView
    activeStreamID = streamID
    activeLabel = label
    self.onMessage = onMessage
    pausedByUser = false
    // PiP で一時停止した後にアプリ側(前面復帰の自動再開など)から再生されたら、PiP のボタン表示も戻す。
    playerStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
      guard player.timeControlStatus == .playing else { return }
      DispatchQueue.main.async {
        guard let self, self.pausedByUser, player === self.player else { return }
        self.pausedByUser = false
        self.renderer?.setPaused(false)
        self.controller?.invalidatePlaybackState()
      }
    }
    PlaybackDiagnostics.log("PiP: \(label) 開始要求")
    postChange()

    // 作った直後のコントローラはまだ「開始可能」になっていないことが多い。可能になった時点で開始する。
    possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self, weak pip] _, change in
      guard change.newValue == true else { return }
      DispatchQueue.main.async {
        guard let self, let pip, pip === self.controller, self.possibleObservation != nil else { return }
        self.possibleObservation = nil
        guard !pip.isPictureInPictureActive else { return }
        pip.startPictureInPicture()
      }
    }
    let timeout = DispatchWorkItem { [weak self, weak pip] in
      guard let self, let pip, pip === self.controller, !pip.isPictureInPictureActive, !self.transitionInProgress else { return }
      PlaybackDiagnostics.log("PiP: \(label) 開始できず(準備がタイムアウト)")
      self.teardown(notify: true)
      onMessage("ピクチャ・イン・ピクチャを開始できませんでした")
    }
    startTimeoutWork = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeout)
  }

  private func teardown(notify: Bool) {
    startTimeoutWork?.cancel()
    startTimeoutWork = nil
    possibleObservation = nil
    playerStatusObservation = nil
    renderer?.stop()
    renderer = nil
    controller?.delegate = nil
    controller = nil
    displayView?.removeFromSuperview()
    displayView = nil
    let endedSource = source
    source = nil
    player = nil
    sourceDanmakuView = nil
    activeStreamID = nil
    activeLabel = ""
    onMessage = nil
    transitionInProgress = false
    closeAfterStart = false
    pausedByUser = false
    endedSource?.pictureInPictureDidEnd()
    if notify {
      postChange()
    }
  }

  private func postChange() {
    NotificationCenter.default.post(name: .multiViewPictureInPictureChanged, object: nil)
  }

  private func schedulePendingStartFallback() {
    pendingStartFallbackWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      // 閉じた通知が来ない時の保険。
      guard let self, self.pendingStart != nil else { return }
      self.teardown(notify: true)
      self.runPendingStart()
    }
    pendingStartFallbackWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
  }

  private func runPendingStart() {
    pendingStartFallbackWork?.cancel()
    pendingStartFallbackWork = nil
    guard let pending = pendingStart else { return }
    pendingStart = nil
    // 閉じるアニメーションの直後は次の PiP の開始に失敗しやすいので少し待つ。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: pending)
  }

  // PiP の「アプリに戻る」で視聴タブを前面にする。
  private static func showViewingTab() {
    guard let tabs = (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController as? UITabBarController,
          let index = tabs.viewControllers?.firstIndex(where: { $0 is ViewingController }),
          tabs.selectedIndex != index else { return }
    tabs.selectedIndex = index
  }

  // MARK: - AVPictureInPictureControllerDelegate

  func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard pictureInPictureController === controller else { return }
    startTimeoutWork?.cancel()
    startTimeoutWork = nil
    transitionInProgress = true
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard pictureInPictureController === controller else { return }
    transitionInProgress = false
    PlaybackDiagnostics.log("PiP: \(activeLabel) 開始")
    if closeAfterStart {
      closeAfterStart = false
      transitionInProgress = true
      pictureInPictureController.stopPictureInPicture()
    }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    guard pictureInPictureController === controller else { return }
    PlaybackDiagnostics.log("PiP: \(activeLabel) 開始失敗(\(error.localizedDescription))")
    let onMessage = self.onMessage
    teardown(notify: true)
    onMessage?("ピクチャ・イン・ピクチャを開始できませんでした")
    runPendingStart()
  }

  func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard pictureInPictureController === controller else { return }
    transitionInProgress = true
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard pictureInPictureController === controller else { return }
    PlaybackDiagnostics.log("PiP: \(activeLabel) 終了")
    teardown(notify: true)
    runPendingStart()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    Self.showViewingTab()
    completionHandler(true)
  }

  // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    guard pictureInPictureController === controller, let player else { return }
    pausedByUser = !playing
    renderer?.setPaused(!playing)
    if playing {
      player.play()
    } else {
      player.pause()
    }
    pictureInPictureController.invalidatePlaybackState()
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
    // ライブ配信: 無限の範囲を返すと PiP は「ライブ」扱いになり、シークバーやスキップを出さない。
    CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
    pausedByUser
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {
    guard pictureInPictureController === controller else { return }
    renderer?.updateRenderSize(width: CGFloat(newRenderSize.width), height: CGFloat(newRenderSize.height))
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }

  func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
    // PiP で一時停止しても他の配信の音声は従来どおり流す。
    false
  }
}

// PiP の中身になる AVSampleBufferDisplayLayer を持つビュー。セルの一番奥に置く。
private final class PictureInPictureDisplayView: UIView {
  override class var layerClass: AnyClass {
    AVSampleBufferDisplayLayer.self
  }

  var displayLayer: AVSampleBufferDisplayLayer {
    // swiftlint:disable:next force_cast
    layer as! AVSampleBufferDisplayLayer
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .black
    displayLayer.videoGravity = .resizeAspect
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

// MARK: - フレーム合成

// コメント 1 件を描いた画像と、配置に使う情報。
private struct PictureInPictureCommentRaster {
  let image: CGImage
  /// 配置に使う大きさ(幅 = 中身の幅、高さ = 1 行の高さ)。px。
  let layoutSize: CGSize
  /// 画像の左上から配置の箱の左上までのずれ(影がはみ出す分の余白)。px。
  let inset: CGFloat
  let position: DanmakuPosition
  /// 描いた時の寸法(出力フレームの大きさと設定)。
  let metrics: DanmakuMetrics
}

// 表示中のコメントの画像。どこに出すかは共通エンジン(DanmakuStage)が持つ。
private struct PictureInPictureCommentImage {
  let image: CGImage
  let inset: CGFloat
  /// 描いた時の出力幅(px)。今の出力幅と同じなら等倍(くっきり)で描く。
  let rasterStageWidth: CGFloat
}

// AVPlayer の映像フレームを受け取り、コメントを描き込んで PiP のレイヤーへ流す。
//
// なめらかさ: 60fps の一定間隔でフレームを作り、各フレームに「この時刻に表示」(表示時刻)を付けて
// 少し先(50ms)まで渡しておく。表示側(AVSampleBufferDisplayLayer＋ホスト時計の controlTimebase)が
// その時刻ちょうどに出すので、こちらの処理時間のばらつきがガタつきにならない。コメントの位置も
// その表示時刻で計算する。映像が 30fps でもコメントは 60fps で動く。
// くっきりさ: 出力フレームは PiP の窓の実ピクセル(長辺640〜1280px)。映像は AVPlayerItemVideoOutput に
// その大きさで出させ(元が 360p でも)、コメントは同じ解像度で等倍・整数位置に描く。
// コメントの配置: タイルの弾幕と同じ共通エンジン(DanmakuEngine.swift。ニコ生公式アプリと同じ規則)。
// 大きさは画面の高さに対する比率なので、タイルでも PiP でも同じ見え方になる。
// メインスレッド: attach/stop/addComment/updateRenderSize/setPaused。それ以外の状態は queue 上だけで触る。
private final class PictureInPictureFrameRenderer {
  private static let frameInterval: CFTimeInterval = 1.0 / 60.0
  private static let presentationLead: CFTimeInterval = 0.05
  private static let defaultLongSide: CGFloat = 960
  private static let minLongSide: CGFloat = 640
  private static let maxLongSide: CGFloat = 1280

  private let queue = DispatchQueue(label: "app.multiview.pip.render", qos: .userInteractive)
  private let displayLayer: AVSampleBufferDisplayLayer
  private let label: String
  private let screenScale: CGFloat
  private let colorSpace = CGColorSpaceCreateDeviceRGB()
  private let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
  private let placeholderText: CGImage?

  // メインスレッド専用
  private weak var player: AVPlayer?
  private var itemObservation: NSKeyValueObservation?
  private var presentationSizeObservation: NSKeyValueObservation?
  private weak var attachedItem: AVPlayerItem?
  private var attachedOutput: AVPlayerItemVideoOutput?
  private var renderLongSidePixels: CGFloat = 0
  private var videoAspect: CGFloat = 9.0 / 16.0   // 高さ/幅
  private var outputSizeMain: CGSize
  private var loggedRenderSize = false

  // queue 専用
  private var timer: DispatchSourceTimer?
  private var output: AVPlayerItemVideoOutput?
  private var outputSize: CGSize
  private var latestVideoFrame: CVPixelBuffer?
  // 表示中のコメントの配置(タイルの弾幕と同じ共通エンジン)と、その画像。
  private var stage: DanmakuStage
  private var commentImages: [Int: PictureInPictureCommentImage] = [:]
  private var lastPresentationTime: CFTimeInterval = 0
  private var pausedAt: CFTimeInterval?
  private var pausedTotal: CFTimeInterval = 0
  private var needsFrame = true
  private var lastVideoAt: CFTimeInterval = 0
  private var outputAttachedAt: CFTimeInterval = 0
  private var receivedVideo = false
  private var stallLogged = false
  private var framePool: CVPixelBufferPool?
  private var framePoolSize = CGSize.zero
  private var scalePool: CVPixelBufferPool?
  private var scalePoolSize = CGSize.zero
  private var formatDescription: CMVideoFormatDescription?

  init(displayLayer: AVSampleBufferDisplayLayer, label: String, screenScale: CGFloat) {
    self.displayLayer = displayLayer
    self.label = label
    self.screenScale = max(1, screenScale)
    placeholderText = Self.makePlaceholderText()
    let initialSize = Self.makeOutputSize(longSide: Self.defaultLongSide, aspect: 9.0 / 16.0)
    outputSizeMain = initialSize
    outputSize = initialSize
    stage = DanmakuStage(metrics: DanmakuMetrics(
      stageSize: initialSize,
      fontSetting: DanmakuMetrics.defaultFontSetting,
      speedSetting: DanmakuMetrics.defaultSpeedSetting,
      maxLines: 0
    ))
    // 表示側の時計をホスト時刻(CACurrentMediaTime と同じ)にする。
    var timebase: CMTimebase?
    CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(),
      timebaseOut: &timebase
    )
    if let timebase {
      CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
      CMTimebaseSetRate(timebase, rate: 1)
      displayLayer.controlTimebase = timebase
    }
  }

  // MARK: メインスレッド

  func attach(player: AVPlayer) {
    self.player = player
    // 再接続などで AVPlayerItem が差し替わったら、新しい item に映像出力を付け直す。
    itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
      let item = player.currentItem
      DispatchQueue.main.async {
        self?.attachOutput(to: item)
      }
    }
  }

  func start() {
    queue.async {
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(1))
      timer.setEventHandler { [weak self] in
        self?.tick()
      }
      timer.resume()
      self.timer = timer
    }
  }

  func stop() {
    itemObservation = nil
    presentationSizeObservation = nil
    if let attachedItem, let attachedOutput {
      attachedItem.remove(attachedOutput)
    }
    attachedItem = nil
    attachedOutput = nil
    let layer = displayLayer
    queue.async {
      self.timer?.cancel()
      self.timer = nil
      self.output = nil
      self.latestVideoFrame = nil
      self.commentImages.removeAll()
      layer.flushAndRemoveImage()
    }
  }

  // PiP の一時停止。止めている間はフレームを作らず(最後の絵のまま)、コメントの時計も止める。
  func setPaused(_ paused: Bool) {
    queue.async {
      let now = CACurrentMediaTime()
      if paused {
        if self.pausedAt == nil {
          self.pausedAt = now
        }
      } else if let pausedAt = self.pausedAt {
        self.pausedTotal += now - pausedAt
        self.pausedAt = nil
        self.needsFrame = true
      }
    }
  }

  func updateRenderSize(width: CGFloat, height: CGFloat) {
    guard width > 0, height > 0 else { return }
    var longSide = max(width, height)
    // 単位がポイントで来た場合の保険(PiP の窓が 120pt 未満になることはない)。
    if longSide / screenScale < 120 {
      longSide *= screenScale
    }
    renderLongSidePixels = longSide
    if !loggedRenderSize {
      loggedRenderSize = true
      PlaybackDiagnostics.log("PiP: 窓サイズ \(Int(width))x\(Int(height))")
    }
    updateOutputSize()
  }

  func addComment(tokens: [NativeDanmakuToken], settings: AppSettings, style: DanmakuStyle) {
    // 大きさ・速さは、出力フレーム(=PiP の窓)の大きさと設定から共通エンジンの規則で決まる。
    let metrics = DanmakuMetrics(
      stageSize: outputSizeMain,
      fontSetting: settings.danmakuFontSize,
      speedSetting: settings.danmakuSpeed,
      maxLines: settings.danmakuMaxLines
    )
    PictureInPictureCommentRasterizer.render(
      tokens: tokens,
      metrics: metrics,
      style: style,
      opacity: settings.danmakuOpacity
    ) { [weak self] raster in
      guard let self, let raster else { return }
      self.queue.async {
        self.insert(raster)
      }
    }
  }

  // 出力フレームの大きさ = PiP の窓の実ピクセル(不明な間は長辺960px)× 映像の縦横比。
  private func updateOutputSize() {
    let longSide = renderLongSidePixels > 0 ? renderLongSidePixels : Self.defaultLongSide
    let size = Self.makeOutputSize(longSide: longSide, aspect: videoAspect)
    guard size != outputSizeMain else { return }
    outputSizeMain = size
    queue.async {
      self.outputSize = size
      // 表示中のコメントも新しい大きさへ比例で合わせる。
      self.stage.rescale(to: self.stage.metrics.resized(to: size))
      self.needsFrame = true
    }
    if let attachedItem {
      attachOutput(to: attachedItem, force: true)
    }
  }

  private func videoSizeChanged(_ size: CGSize, item: AVPlayerItem) {
    guard item === attachedItem, size.width > 0, size.height > 0 else { return }
    let aspect = size.height / size.width
    guard abs(aspect - videoAspect) > 0.01 else { return }
    videoAspect = aspect
    updateOutputSize()
  }

  private func attachOutput(to item: AVPlayerItem?, force: Bool = false) {
    guard itemObservation != nil else { return }
    if !force, item === attachedItem { return }
    if let attachedItem, let attachedOutput {
      attachedItem.remove(attachedOutput)
    }
    if item !== attachedItem {
      presentationSizeObservation = nil
      if let item {
        // 映像の縦横比(ツイキャスの縦長配信など)に出力フレームを合わせる。
        presentationSizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
          let size = item.presentationSize
          DispatchQueue.main.async {
            self?.videoSizeChanged(size, item: item)
          }
        }
      }
    }
    attachedItem = item
    attachedOutput = nil
    var newOutput: AVPlayerItemVideoOutput?
    if let item {
      // 映像はこの大きさ・BGRA で出させる(縮小/拡大は AVFoundation 側。元が 360p でも PiP の解像度で受け取る)。
      let size = outputSizeMain
      let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
      ])
      item.add(videoOutput)
      attachedOutput = videoOutput
      newOutput = videoOutput
      scheduleNoFrameNudge(item: item, output: videoOutput)
    }
    queue.async {
      self.output = newOutput
      self.outputAttachedAt = CACurrentMediaTime()
    }
  }

  // 再生中の HLS に後から映像出力を付けると、フレームが来ないことがある。2.5秒待っても来なければ、
  // 今の位置へシークし直して映像の流れを作り直す(一度だけ。わずかに引っかかる程度)。
  private func scheduleNoFrameNudge(item: AVPlayerItem, output: AVPlayerItemVideoOutput) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak item, weak output] in
      guard let self, let item, let output, item === self.attachedItem, output === self.attachedOutput else { return }
      self.queue.async {
        let gotFrames = self.lastVideoAt >= self.outputAttachedAt
        guard !gotFrames, self.pausedAt == nil else { return }
        DispatchQueue.main.async {
          guard item === self.attachedItem, self.player?.timeControlStatus == .playing else { return }
          PlaybackDiagnostics.log("PiP: \(self.label) 映像フレームが来ないため再生位置を合わせ直し")
          item.seek(to: item.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        }
      }
    }
  }

  // MARK: queue

  private func tick() {
    guard pausedAt == nil else { return }
    let now = CACurrentMediaTime()
    let interval = Self.frameInterval
    // 次に作るフレームの表示時刻。60fps の格子にそろえ、少し先にしておく。
    let target = ceil((now + Self.presentationLead) / interval) * interval
    guard target > lastPresentationTime + interval * 0.5 else { return }
    pullVideoFrame(for: target, now: now)
    let commentTime = target - pausedTotal
    for id in stage.removeFinished(now: commentTime) {
      commentImages[id] = nil
    }
    if !needsFrame, stage.items.isEmpty {
      // 新しい映像もコメントも無ければ作らない(省電力)。読み込み中のつなぎ画面だけは時々出す。
      let placeholderDue = latestVideoFrame == nil && target - lastPresentationTime >= 1.0 / 15.0
      if !placeholderDue {
        logStallIfNeeded(now: now)
        return
      }
    }
    guard let frame = Self.makeBuffer(pool: &framePool, poolSize: &framePoolSize, size: outputSize) else { return }
    compose(into: frame, commentTime: commentTime)
    enqueue(frame, presentationTime: target)
    lastPresentationTime = target
    needsFrame = false
    logStallIfNeeded(now: now)
  }

  private func pullVideoFrame(for target: CFTimeInterval, now: CFTimeInterval) {
    guard let output else { return }
    let itemTime = output.itemTime(forHostTime: target)
    guard output.hasNewPixelBuffer(forItemTime: itemTime),
          let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
    noteVideoFrame(pixelBuffer, now: now)
    latestVideoFrame = conformedToOutputSize(pixelBuffer)
    needsFrame = true
  }

  // 映像出力が指定の大きさで出してこなかった時だけ、こちらで縮尺を合わせる(普段は何もしない)。
  private func conformedToOutputSize(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
    let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
    let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
    guard width != outputSize.width || height != outputSize.height,
          CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
          let scaled = Self.makeBuffer(pool: &scalePool, poolSize: &scalePoolSize, size: outputSize) else {
      return pixelBuffer
    }
    CVPixelBufferLockBaseAddress(scaled, [])
    defer { CVPixelBufferUnlockBaseAddress(scaled, []) }
    guard let base = CVPixelBufferGetBaseAddress(scaled) else { return pixelBuffer }
    Self.copy(
      pixelBuffer,
      into: base,
      width: CVPixelBufferGetWidth(scaled),
      height: CVPixelBufferGetHeight(scaled),
      bytesPerRow: CVPixelBufferGetBytesPerRow(scaled)
    )
    return scaled
  }

  private func noteVideoFrame(_ pixelBuffer: CVPixelBuffer, now: CFTimeInterval) {
    if !receivedVideo {
      receivedVideo = true
      PlaybackDiagnostics.log("PiP: \(label) 映像フレーム受信 \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
    }
    if stallLogged {
      stallLogged = false
      PlaybackDiagnostics.log("PiP: \(label) 映像フレーム再開")
    }
    lastVideoAt = now
  }

  private func logStallIfNeeded(now: CFTimeInterval) {
    guard receivedVideo, pausedAt == nil, !stallLogged, now - lastVideoAt > 4 else { return }
    stallLogged = true
    let label = self.label
    DispatchQueue.main.async {
      let background = UIApplication.shared.applicationState == .background
      PlaybackDiagnostics.log("PiP: \(label) 映像フレームが4秒以上届いていません(\(background ? "バックグラウンド" : "前面"))")
    }
  }

  // コメントを流し始める。何段目に出すか・どの速さで流すかは共通エンジン(DanmakuStage)が決める。
  private func insert(_ raster: PictureInPictureCommentRaster) {
    var metrics = raster.metrics
    var layoutSize = raster.layoutSize
    if metrics.stageSize != outputSize, metrics.stageSize.width > 0 {
      // 描いている間に出力の大きさが変わった。今の大きさに合わせて置く(画像は描く時に拡大縮小される)。
      let factor = outputSize.width / metrics.stageSize.width
      layoutSize = CGSize(width: layoutSize.width * factor, height: layoutSize.height * factor)
      metrics = metrics.resized(to: outputSize)
    }
    stage.rescale(to: metrics)
    // 次に作るフレームから動き出すように、そのフレームのコメント時刻で置く。
    let now = (pausedAt ?? CACurrentMediaTime()) + Self.presentationLead - pausedTotal
    let placement = stage.add(position: raster.position, size: layoutSize, now: now)
    for id in placement.evictedIDs {
      commentImages[id] = nil
    }
    commentImages[placement.item.id] = PictureInPictureCommentImage(
      image: raster.image,
      inset: raster.inset,
      rasterStageWidth: raster.metrics.stageSize.width
    )
  }

  // 出力フレーム = 最新の映像(無ければ黒地＋「映像を準備中」)＋その表示時刻の位置のコメント。
  // バックグラウンドでは GPU を使えないので CPU(memcpy＋CoreGraphics)で描く。
  private func compose(into frame: CVPixelBuffer, commentTime: CFTimeInterval) {
    CVPixelBufferLockBaseAddress(frame, [])
    defer { CVPixelBufferUnlockBaseAddress(frame, []) }
    guard let base = CVPixelBufferGetBaseAddress(frame) else { return }
    let width = CVPixelBufferGetWidth(frame)
    let height = CVPixelBufferGetHeight(frame)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(frame)
    if let latestVideoFrame {
      Self.copy(latestVideoFrame, into: base, width: width, height: height, bytesPerRow: bytesPerRow)
    }
    guard let context = CGContext(
      data: base,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: bitmapInfo
    ) else { return }
    let frameWidth = CGFloat(width)
    let frameHeight = CGFloat(height)
    if latestVideoFrame == nil {
      context.setFillColor(UIColor.black.cgColor)
      context.fill(CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
      if let placeholderText {
        let textWidth = min(frameWidth * 0.5, CGFloat(placeholderText.width))
        let textHeight = textWidth * CGFloat(placeholderText.height) / CGFloat(max(1, placeholderText.width))
        context.draw(placeholderText, in: CGRect(
          x: ((frameWidth - textWidth) / 2).rounded(),
          y: ((frameHeight - textHeight) / 2).rounded(),
          width: textWidth,
          height: textHeight
        ))
      }
    }
    context.interpolationQuality = .medium
    for item in stage.items {
      guard let comment = commentImages[item.id] else { continue }
      // 描いた時と出力幅が同じなら等倍。整数位置に置いて文字をぼかさない。
      let scale = frameWidth / comment.rasterStageWidth
      let drawWidth = CGFloat(comment.image.width) * scale
      let drawHeight = CGFloat(comment.image.height) * scale
      let x = (item.x(at: commentTime) - comment.inset * scale).rounded()
      guard x < frameWidth, x + drawWidth > 0 else { continue }
      let top = (item.y - comment.inset * scale).rounded()
      // CGContext は左下原点。ピクセルバッファの先頭行は映像の上端。
      context.draw(comment.image, in: CGRect(x: x, y: frameHeight - top - drawHeight, width: drawWidth, height: drawHeight))
    }
  }

  // BGRA の映像をフレームのメモリへ写す。同じ大きさなら memcpy、違えば vImage で縮尺を合わせる。
  private static func copy(_ source: CVPixelBuffer, into destination: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int) {
    guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else { return }
    CVPixelBufferLockBaseAddress(source, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard let sourceBase = CVPixelBufferGetBaseAddress(source) else { return }
    let sourceWidth = CVPixelBufferGetWidth(source)
    let sourceHeight = CVPixelBufferGetHeight(source)
    let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(source)
    if sourceWidth == width, sourceHeight == height {
      if sourceBytesPerRow == bytesPerRow {
        memcpy(destination, sourceBase, bytesPerRow * height)
      } else {
        let rowBytes = min(sourceBytesPerRow, bytesPerRow)
        for row in 0..<height {
          memcpy(destination + row * bytesPerRow, sourceBase + row * sourceBytesPerRow, rowBytes)
        }
      }
      return
    }
    var sourceBuffer = vImage_Buffer(
      data: sourceBase,
      height: vImagePixelCount(sourceHeight),
      width: vImagePixelCount(sourceWidth),
      rowBytes: sourceBytesPerRow
    )
    var destinationBuffer = vImage_Buffer(
      data: destination,
      height: vImagePixelCount(height),
      width: vImagePixelCount(width),
      rowBytes: bytesPerRow
    )
    vImageScale_ARGB8888(&sourceBuffer, &destinationBuffer, nil, vImage_Flags(kvImageNoFlags))
  }

  private static func makeBuffer(pool: inout CVPixelBufferPool?, poolSize: inout CGSize, size: CGSize) -> CVPixelBuffer? {
    if pool == nil || poolSize != size {
      let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
      ]
      var newPool: CVPixelBufferPool?
      CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool)
      pool = newPool
      poolSize = size
    }
    guard let readyPool = pool else { return nil }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, readyPool, &buffer)
    return buffer
  }

  private func enqueue(_ pixelBuffer: CVPixelBuffer, presentationTime: CFTimeInterval) {
    if let current = formatDescription, CMVideoFormatDescriptionMatchesImageBuffer(current, imageBuffer: pixelBuffer) {
      // 同じ形式のフレーム。作り直さない。
    } else {
      var description: CMVideoFormatDescription?
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &description
      )
      formatDescription = description
    }
    guard let formatDescription else { return }
    // 表示時刻つきで渡す(controlTimebase がホスト時刻なので、この時刻ちょうどに表示される)。
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 60),
      presentationTimeStamp: CMTime(seconds: presentationTime, preferredTimescale: 1_000_000_000),
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else { return }
    if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
      // バックグラウンドからの復帰や端末ロックの後は、flush するまでフレームを受け付けない
      // (公式アプリも requiresFlushToResumeDecoding を見て flush している)。
      displayLayer.flush()
    }
    guard displayLayer.isReadyForMoreMediaData else { return }
    displayLayer.enqueue(sampleBuffer)
  }

  private static func makeOutputSize(longSide: CGFloat, aspect: CGFloat) -> CGSize {
    let side = min(maxLongSide, max(minLongSide, longSide))
    let width: CGFloat
    let height: CGFloat
    if aspect <= 1 {
      width = side
      height = side * aspect
    } else {
      height = side
      width = side / aspect
    }
    return CGSize(width: even(width), height: even(height))
  }

  private static func even(_ value: CGFloat) -> CGFloat {
    max(2, (value / 2).rounded() * 2)
  }

  private static func makePlaceholderText() -> CGImage? {
    let text = "映像を準備中…" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: 44, weight: .semibold),
      .foregroundColor: UIColor.white.withAlphaComponent(0.75)
    ]
    let size = text.size(withAttributes: attributes)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    format.preferredRange = .standard
    let image = UIGraphicsImageRenderer(
      size: CGSize(width: ceil(size.width), height: ceil(size.height)),
      format: format
    ).image { _ in
      text.draw(at: .zero, withAttributes: attributes)
    }
    return image.cgImage
  }
}

// コメント 1 件を画像にする(メインスレッド)。見た目の寸法はタイルの弾幕と同じ DanmakuAppearance:
// 太字の文字＋影、絵文字は画像、自分のコメントは黄色の枠。出力フレームと同じピクセル密度で描く。
private enum PictureInPictureCommentRasterizer {
  static func render(
    tokens: [NativeDanmakuToken],
    metrics: DanmakuMetrics,
    style: DanmakuStyle,
    opacity: Double,
    completion: @escaping (PictureInPictureCommentRaster?) -> Void
  ) {
    var urls: [URL] = []
    for token in tokens {
      if case .image(let url) = token, !urls.contains(url) {
        urls.append(url)
      }
    }
    if urls.isEmpty {
      completion(draw(tokens: tokens, metrics: metrics, style: style, opacity: opacity, images: [:]))
      return
    }
    // 絵文字画像を待ってから描く。読み込みが遅い時は、来ていない絵文字を省いて流す。
    var images: [URL: UIImage] = [:]
    var finished = false
    let finish = {
      guard !finished else { return }
      finished = true
      completion(draw(tokens: tokens, metrics: metrics, style: style, opacity: opacity, images: images))
    }
    let group = DispatchGroup()
    for url in urls {
      group.enter()
      NativeDanmakuRenderer.fetchImage(url) { image in
        if let image {
          images[url] = image
        }
        group.leave()
      }
    }
    group.notify(queue: .main) {
      finish()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
      finish()
    }
  }

  private static func draw(
    tokens: [NativeDanmakuToken],
    metrics: DanmakuMetrics,
    style: DanmakuStyle,
    opacity: Double,
    images: [URL: UIImage]
  ) -> PictureInPictureCommentRaster? {
    let normal = DanmakuAppearance(metrics: metrics, style: style, opacity: opacity)
    guard let raster = draw(tokens: tokens, appearance: normal, position: style.position, metrics: metrics, images: images) else {
      return nil
    }
    let stageWidth = metrics.stageSize.width
    guard style.position != .flow, stageWidth > 0, raster.layoutSize.width > stageWidth else { return raster }
    // 上/下に固定するコメントが画面より広い時は、収まる大きさまで縮める(公式と同じ)。
    let fitted = DanmakuAppearance(metrics: metrics, style: style, opacity: opacity, scale: stageWidth / raster.layoutSize.width)
    return draw(tokens: tokens, appearance: fitted, position: style.position, metrics: metrics, images: images) ?? raster
  }

  private static func draw(
    tokens: [NativeDanmakuToken],
    appearance: DanmakuAppearance,
    position: DanmakuPosition,
    metrics: DanmakuMetrics,
    images: [URL: UIImage]
  ) -> PictureInPictureCommentRaster? {
    let lineHeight = appearance.lineHeight
    let attributes = appearance.textAttributes
    // 影がはみ出す分の余白を、配置の箱の外側に取る。
    let inset = appearance.shadowReach + 1
    let textHeight = ceil(appearance.font.lineHeight)

    enum Piece {
      case text(NSString, CGFloat)
      case image(UIImage, CGFloat)
    }
    var pieces: [Piece] = []
    var x = appearance.horizontalPadding
    for token in tokens {
      switch token {
      case .text(let text):
        guard !text.isEmpty else { continue }
        let string = text as NSString
        pieces.append(.text(string, x))
        x += ceil(string.size(withAttributes: attributes).width)
      case .image(let url):
        guard let image = images[url] else { continue }
        pieces.append(.image(image.images?.first ?? image, x + appearance.imageGap))
        x += appearance.imageSide + appearance.imageGap * 2
      }
    }
    guard !pieces.isEmpty else { return nil }
    // 配置の箱(幅 = 中身の幅、高さ = 1 行の高さ)。タイルの弾幕のビューと同じ決め方。
    let layoutSize = CGSize(width: ceil(x + appearance.horizontalPadding), height: lineHeight)
    let size = CGSize(width: layoutSize.width + inset * 2, height: ceil(lineHeight) + inset * 2)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    format.preferredRange = .standard
    let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      if appearance.borderWidth > 0 {
        let half = appearance.borderWidth / 2
        let rect = CGRect(
          x: inset + half,
          y: inset + half,
          width: layoutSize.width - appearance.borderWidth,
          height: lineHeight - appearance.borderWidth
        )
        let path = UIBezierPath(roundedRect: rect, cornerRadius: appearance.cornerRadius)
        UIColor.systemYellow.withAlphaComponent(0.12).setFill()
        path.fill()
        path.lineWidth = appearance.borderWidth
        UIColor.systemYellow.setStroke()
        path.stroke()
      }
      let textTop = inset + ((lineHeight - textHeight) / 2).rounded()
      for piece in pieces {
        switch piece {
        case .text(let string, let originX):
          string.draw(at: CGPoint(x: inset + originX, y: textTop), withAttributes: attributes)
        case .image(let image, let originX):
          image.draw(
            in: CGRect(x: inset + originX, y: inset, width: appearance.imageSide, height: appearance.imageSide),
            blendMode: .normal,
            alpha: appearance.imageAlpha
          )
        }
      }
    }
    guard let cgImage = image.cgImage else { return nil }
    return PictureInPictureCommentRaster(image: cgImage, layoutSize: layoutSize, inset: inset, position: position, metrics: metrics)
  }
}
