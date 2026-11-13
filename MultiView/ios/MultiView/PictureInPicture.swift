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
// バックグラウンドでは GPU を使えないため、描き込みは CPU(CoreGraphics)で、変化するコメント部分だけ
// 行う。Amazon IVS(Kick/Twitch)からは映像フレームを取り出せないので、PiP の間だけ AVPlayer 再生へ
// 切り替える(閉じたら IVS へ戻す)。

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
  func mirrorDanmaku(tokens: [NativeDanmakuToken], filterText: String, from root: UIView, settings: AppSettings, highlighted: Bool) {
    guard let renderer, root === sourceDanmakuView else { return }
    renderer.addComment(tokens: tokens, settings: settings, highlighted: highlighted)
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

// 1 コメント分の描画済み画像と、それを描いた時の基準寸法。
private struct PictureInPictureCommentGeometry {
  let rasterWidth: CGFloat        // コメント画像を描いた時の基準フレーム幅(px)
  let rasterHeight: CGFloat       // 同・高さ(px)。フレームの縦横比から決める
  let pipWidthPoints: CGFloat     // その時の PiP 窓の幅(pt)
  let pixelsPerPoint: CGFloat
  let fontSize: CGFloat           // px
  let lineHeight: CGFloat         // px
  let speed: CGFloat              // 1秒あたりに進むフレーム幅の割合
  let maxLinesSetting: Int
}

private struct PictureInPictureCommentRaster {
  let image: CGImage
  let size: CGSize                // px
  let geometry: PictureInPictureCommentGeometry
}

// 流れているコメント。位置はフレームに対する割合(0〜1)で持ち、画質切替でフレーム寸法が変わっても崩れない。
private struct PictureInPictureComment {
  let image: CGImage
  let lane: Int
  let top: CGFloat
  let width: CGFloat
  let height: CGFloat
  let startClock: CFTimeInterval
  let startX: CGFloat
  let speed: CGFloat

  func x(at clock: CFTimeInterval) -> CGFloat {
    startX - speed * CGFloat(clock - startClock)
  }

  func rightEdge(at clock: CFTimeInterval) -> CGFloat {
    x(at: clock) + width
  }
}

// AVPlayer の映像フレームを受け取り、コメントを描き込んで PiP のレイヤーへ流す。
// メインスレッド: attach/stop/addComment/updateRenderSize/setPaused。それ以外の状態は queue 上だけで触る。
private final class PictureInPictureFrameRenderer {
  private static let outputAttributes: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
  ]
  // 同時に描くコメントの上限(大量の時に CPU と発熱を抑える。古いものから消す)。
  private static let maxComments = 120
  // 合成の最大フレームレート。PiP は小窓なので 30fps で十分。
  private static let minFrameInterval: CFTimeInterval = 1.0 / 31.0

  private let queue = DispatchQueue(label: "app.multiview.pip.render", qos: .userInteractive)
  private let displayLayer: AVSampleBufferDisplayLayer
  private let label: String
  private let screenScale: CGFloat
  private let colorSpace = CGColorSpaceCreateDeviceRGB()
  private let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

  // メインスレッド専用
  private weak var player: AVPlayer?
  private var itemObservation: NSKeyValueObservation?
  private weak var attachedItem: AVPlayerItem?
  private var attachedOutput: AVPlayerItemVideoOutput?
  private var pipWidthPoints: CGFloat = 300
  private var frameAspect: CGFloat = 9.0 / 16.0
  private var loggedRenderSize = false

  // queue 専用
  private var timer: DispatchSourceTimer?
  private var output: AVPlayerItemVideoOutput?
  private var comments: [PictureInPictureComment] = []
  private var laneCursor = 0
  private var clock: CFTimeInterval = 0
  private var lastRenderAt: CFTimeInterval = 0
  private var lastFrameAt: CFTimeInterval = 0
  private var lastPlaceholderAt: CFTimeInterval = 0
  private var lastVideoAt: CFTimeInterval = 0
  private var outputAttachedAt: CFTimeInterval = 0
  private var receivedVideo = false
  private var stallLogged = false
  private var paused = false
  private var frameSize = CGSize.zero
  private var formatDescription: CMVideoFormatDescription?
  private var placeholderPool: CVPixelBufferPool?
  private var placeholderPoolSize = CGSize.zero
  private let placeholderText: CGImage?

  init(displayLayer: AVSampleBufferDisplayLayer, label: String, screenScale: CGFloat) {
    self.displayLayer = displayLayer
    self.label = label
    self.screenScale = max(1, screenScale)
    placeholderText = Self.makePlaceholderText()
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
      timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
      timer.setEventHandler { [weak self] in
        self?.tick()
      }
      timer.resume()
      self.timer = timer
    }
  }

  func stop() {
    itemObservation = nil
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
      self.comments.removeAll()
      layer.flushAndRemoveImage()
    }
  }

  func setPaused(_ paused: Bool) {
    queue.async {
      self.paused = paused
    }
  }

  func updateRenderSize(width: CGFloat, height: CGFloat) {
    guard width > 0 else { return }
    var points = width / screenScale
    // 単位がポイントで来た場合の保険(PiP の窓が 120pt 未満になることはない)。
    if points < 120 {
      points = width
    }
    pipWidthPoints = max(120, points)
    if !loggedRenderSize {
      loggedRenderSize = true
      PlaybackDiagnostics.log("PiP: 窓サイズ \(Int(width))x\(Int(height))")
    }
  }

  func addComment(tokens: [NativeDanmakuToken], settings: AppSettings, highlighted: Bool) {
    let geometry = makeGeometry(settings: settings)
    PictureInPictureCommentRasterizer.render(
      tokens: tokens,
      geometry: geometry,
      opacity: CGFloat(settings.danmakuOpacity),
      highlighted: highlighted
    ) { [weak self] raster in
      guard let self, let raster else { return }
      self.queue.async {
        self.insert(raster)
      }
    }
  }

  // セルの弾幕と同じ見た目の比率(フォント・行高・速さ)を、PiP の窓の大きさに合わせて求める。
  private func makeGeometry(settings: AppSettings) -> PictureInPictureCommentGeometry {
    let pipWidth = max(120, pipWidthPoints)
    // コメント画像は PiP の窓の実ピクセル程度で描けば十分(大きすぎると大量コメント時にメモリを食う)。
    let rasterWidth = min(960, max(480, pipWidth * screenScale))
    let pixelsPerPoint = rasterWidth / pipWidth
    let fontPoints = (CGFloat(settings.danmakuFontSize) * min(1.8, max(0.55, pipWidth / 340))).rounded()
    let speedPoints = max(35, pipWidth * CGFloat(settings.danmakuSpeed))
    return PictureInPictureCommentGeometry(
      rasterWidth: rasterWidth,
      rasterHeight: rasterWidth * frameAspect,
      pipWidthPoints: pipWidth,
      pixelsPerPoint: pixelsPerPoint,
      fontSize: fontPoints * pixelsPerPoint,
      lineHeight: (fontPoints + 8) * pixelsPerPoint,
      speed: speedPoints / pipWidth,
      maxLinesSetting: settings.danmakuMaxLines
    )
  }

  private func attachOutput(to item: AVPlayerItem?) {
    guard itemObservation != nil, item !== attachedItem else { return }
    if let attachedItem, let attachedOutput {
      attachedItem.remove(attachedOutput)
    }
    attachedItem = item
    attachedOutput = nil
    var newOutput: AVPlayerItemVideoOutput?
    if let item {
      let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: Self.outputAttributes)
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
        guard !gotFrames, !self.paused else { return }
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
    let now = CACurrentMediaTime()
    if let output {
      let itemTime = output.itemTime(forHostTime: now)
      if output.hasNewPixelBuffer(forItemTime: itemTime) {
        guard now - lastFrameAt >= Self.minFrameInterval else { return }
        if let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
          lastFrameAt = now
          noteVideoFrame(pixelBuffer, now: now)
          advanceClock(now)
          drawComments(onto: pixelBuffer, clearFirst: false)
          enqueue(pixelBuffer)
          return
        }
      }
    }
    if !receivedVideo {
      // 映像がまだ来ていない間(読み込み中・IVS→AVPlayer 切替中)は、黒地のつなぎ画面にコメントだけ流す。
      if now - lastPlaceholderAt >= 1.0 / 15.0 {
        lastPlaceholderAt = now
        renderPlaceholder(now: now)
      }
      return
    }
    if !paused, !stallLogged, now - lastVideoAt > 4 {
      stallLogged = true
      let label = self.label
      DispatchQueue.main.async {
        let background = UIApplication.shared.applicationState == .background
        PlaybackDiagnostics.log("PiP: \(label) 映像フレームが4秒以上届いていません(\(background ? "バックグラウンド" : "前面"))")
      }
    }
  }

  private func noteVideoFrame(_ pixelBuffer: CVPixelBuffer, now: CFTimeInterval) {
    let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    if !receivedVideo {
      receivedVideo = true
      PlaybackDiagnostics.log("PiP: \(label) 映像フレーム受信 \(Int(size.width))x\(Int(size.height))")
    }
    if stallLogged {
      stallLogged = false
      PlaybackDiagnostics.log("PiP: \(label) 映像フレーム再開")
    }
    lastVideoAt = now
    if size != frameSize, size.width > 0, size.height > 0 {
      frameSize = size
      let aspect = size.height / size.width
      DispatchQueue.main.async { [weak self] in
        self?.frameAspect = aspect
      }
    }
  }

  // コメントの時計は「描いたフレーム」ごとにだけ進める(最大0.1秒)。一時停止や映像の停止中は
  // コメントも止まり、再開時にまとめて飛ばない。
  private func advanceClock(_ now: CFTimeInterval) {
    if lastRenderAt > 0 {
      clock += min(max(now - lastRenderAt, 0), 0.1)
    }
    lastRenderAt = now
  }

  private func insert(_ raster: PictureInPictureCommentRaster) {
    let geometry = raster.geometry
    let laneHeight = geometry.lineHeight / geometry.rasterHeight
    let topMargin = 6 * geometry.pixelsPerPoint / geometry.rasterHeight
    let fittingLines = max(1, Int((1 - topMargin) / laneHeight))
    let maxLines = geometry.maxLinesSetting > 0 ? min(geometry.maxLinesSetting, fittingLines) : fittingLines
    // セルの弾幕と同じく、先頭のコメントが十分入ってきたレーンを選ぶ。全レーンが詰まっていても
    // 捨てずに、先頭が一番左にあるレーンへ流す。
    let clearThreshold = 1 - 36 / geometry.pipWidthPoints
    var laneFront: [Int: CGFloat] = [:]
    for comment in comments where comment.lane < maxLines {
      laneFront[comment.lane] = max(laneFront[comment.lane] ?? -1, comment.rightEdge(at: clock))
    }
    var chosen: Int?
    for offset in 0..<maxLines {
      let candidate = (laneCursor + offset) % maxLines
      if (laneFront[candidate] ?? -1) < clearThreshold {
        chosen = candidate
        break
      }
    }
    let lane = chosen ?? (0..<maxLines).min { (laneFront[$0] ?? -1) < (laneFront[$1] ?? -1) } ?? 0
    laneCursor += 1
    comments.append(PictureInPictureComment(
      image: raster.image,
      lane: lane,
      top: topMargin + CGFloat(lane) * laneHeight,
      width: raster.size.width / geometry.rasterWidth,
      height: raster.size.height / geometry.rasterHeight,
      startClock: clock,
      startX: 1 + 12 / geometry.pipWidthPoints,
      speed: geometry.speed
    ))
    if comments.count > Self.maxComments {
      comments.removeFirst(comments.count - Self.maxComments)
    }
  }

  // フレームにコメントを直接描き込む(CPU。バックグラウンドでは GPU を使えないため)。
  private func drawComments(onto pixelBuffer: CVPixelBuffer, clearFirst: Bool) {
    comments.removeAll { $0.rightEdge(at: clock) < -0.02 }
    guard clearFirst || !comments.isEmpty,
          CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard let context = CGContext(
      data: base,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
      space: colorSpace,
      bitmapInfo: bitmapInfo
    ) else { return }
    let frameWidth = CGFloat(width)
    let frameHeight = CGFloat(height)
    if clearFirst {
      context.setFillColor(UIColor.black.cgColor)
      context.fill(CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
      if let placeholderText {
        let textWidth = min(frameWidth * 0.6, CGFloat(placeholderText.width))
        let textHeight = textWidth * CGFloat(placeholderText.height) / CGFloat(max(1, placeholderText.width))
        context.draw(placeholderText, in: CGRect(
          x: (frameWidth - textWidth) / 2,
          y: (frameHeight - textHeight) / 2,
          width: textWidth,
          height: textHeight
        ))
      }
    }
    context.interpolationQuality = .medium
    for comment in comments {
      let x = comment.x(at: clock) * frameWidth
      let w = comment.width * frameWidth
      guard x < frameWidth, x + w > 0 else { continue }
      let h = comment.height * frameHeight
      let top = comment.top * frameHeight
      // CGContext は左下原点。ピクセルバッファの先頭行は映像の上端。
      context.draw(comment.image, in: CGRect(x: x, y: frameHeight - top - h, width: w, height: h))
    }
  }

  private func renderPlaceholder(now: CFTimeInterval) {
    let size = frameSize.width > 0 ? frameSize : CGSize(width: 1280, height: 720)
    guard let pixelBuffer = makePlaceholderBuffer(size: size) else { return }
    advanceClock(now)
    drawComments(onto: pixelBuffer, clearFirst: true)
    enqueue(pixelBuffer)
  }

  private func makePlaceholderBuffer(size: CGSize) -> CVPixelBuffer? {
    if placeholderPool == nil || placeholderPoolSize != size {
      let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
      ]
      var pool: CVPixelBufferPool?
      CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
      placeholderPool = pool
      placeholderPoolSize = size
    }
    guard let placeholderPool else { return nil }
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, placeholderPool, &pixelBuffer)
    return pixelBuffer
  }

  private func enqueue(_ pixelBuffer: CVPixelBuffer) {
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
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
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
    // ライブの映像は届いた順にすぐ出す(再生時刻の管理はしない)。
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
       CFArrayGetCount(attachments) > 0 {
      let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dictionary,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
    if displayLayer.status == .failed {
      // バックグラウンドからの復帰などで failed になると、flush するまで受け付けない。
      displayLayer.flush()
    }
    guard displayLayer.isReadyForMoreMediaData else { return }
    displayLayer.enqueue(sampleBuffer)
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

// コメント 1 件を画像にする(メインスレッド)。見た目はセルの弾幕(NativeDanmakuRenderer)に合わせる:
// 太字の白文字＋黒い影、絵文字は画像、自分のコメントは黄色の枠。
private enum PictureInPictureCommentRasterizer {
  static func render(
    tokens: [NativeDanmakuToken],
    geometry: PictureInPictureCommentGeometry,
    opacity: CGFloat,
    highlighted: Bool,
    completion: @escaping (PictureInPictureCommentRaster?) -> Void
  ) {
    var urls: [URL] = []
    for token in tokens {
      if case .image(let url) = token, !urls.contains(url) {
        urls.append(url)
      }
    }
    if urls.isEmpty {
      completion(draw(tokens: tokens, geometry: geometry, opacity: opacity, highlighted: highlighted, images: [:]))
      return
    }
    // 絵文字画像を待ってから描く。読み込みが遅い時は、来ていない絵文字を省いて流す。
    var images: [URL: UIImage] = [:]
    var finished = false
    let finish = {
      guard !finished else { return }
      finished = true
      completion(draw(tokens: tokens, geometry: geometry, opacity: opacity, highlighted: highlighted, images: images))
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
    geometry: PictureInPictureCommentGeometry,
    opacity: CGFloat,
    highlighted: Bool,
    images: [URL: UIImage]
  ) -> PictureInPictureCommentRaster? {
    let ppp = geometry.pixelsPerPoint
    let font = UIFont.systemFont(ofSize: geometry.fontSize, weight: .bold)
    let shadow = NSShadow()
    shadow.shadowColor = UIColor.black
    shadow.shadowBlurRadius = 2 * ppp
    shadow.shadowOffset = CGSize(width: ppp, height: ppp)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: UIColor.white.withAlphaComponent(opacity),
      .shadow: shadow
    ]
    let imageSide = max(18 * ppp, geometry.fontSize * 1.4)
    // 影がはみ出す分と、自分のコメントの枠の分の余白。
    let padding = (highlighted ? 8 : 3) * ppp
    let inset = (highlighted ? 2 : 0) * ppp

    enum Piece {
      case text(NSString, CGFloat)
      case image(UIImage, CGFloat)
    }
    var pieces: [Piece] = []
    var x = padding
    for token in tokens {
      switch token {
      case .text(let text):
        guard !text.isEmpty else { continue }
        let string = text as NSString
        pieces.append(.text(string, x))
        x += ceil(string.size(withAttributes: attributes).width)
      case .image(let url):
        guard let image = images[url] else { continue }
        pieces.append(.image(image.images?.first ?? image, x + 3 * ppp))
        x += imageSide + 6 * ppp
      }
    }
    guard !pieces.isEmpty else { return nil }
    let size = CGSize(width: ceil(x + padding), height: ceil(geometry.lineHeight + inset * 2))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    format.preferredRange = .standard
    let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      if highlighted {
        let rect = CGRect(x: ppp, y: ppp, width: size.width - 2 * ppp, height: size.height - 2 * ppp)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 4 * ppp)
        UIColor.systemYellow.withAlphaComponent(0.12).setFill()
        path.fill()
        path.lineWidth = 2 * ppp
        UIColor.systemYellow.setStroke()
        path.stroke()
      }
      for piece in pieces {
        switch piece {
        case .text(let string, let originX):
          string.draw(at: CGPoint(x: originX, y: inset), withAttributes: attributes)
        case .image(let image, let originX):
          let originY = max(inset, (geometry.lineHeight - imageSide) / 2)
          image.draw(in: CGRect(x: originX, y: originY, width: imageSide, height: imageSide), blendMode: .normal, alpha: opacity)
        }
      }
    }
    guard let cgImage = image.cgImage else { return nil }
    return PictureInPictureCommentRaster(image: cgImage, size: size, geometry: geometry)
  }
}
