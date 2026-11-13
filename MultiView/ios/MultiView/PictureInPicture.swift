import AVFoundation
import AVKit
import UIKit

// ピクチャ・イン・ピクチャ(PiP)。各セルの PiP ボタンでその配信を PiP にし、PiP 上にもコメントを
// 流す(ニコ生公式アプリと同じ体験)。
//
// 映像は iOS 標準の PiP(AVPlayerLayer / Amazon IVS の IVSPlayerLayer)に任せる。アプリを離れても
// システムが映像を描画し続けるため、自前で映像フレームにコメントを合成する方式より確実で軽い。
// コメントは PiP 開始時にアプリ内へ作られる PiP 用の窓(PegasusKit の PGHostedWindow。非公開クラス)の
// 最前面に透明な弾幕レイヤーを重ね、元のセルに流れたコメントを同時にそこへも流す。窓が見つからない
// iOS では映像だけの PiP になる(再生は壊れない)。

/// PiP にできるプレイヤー(各ネイティブプレイヤーが準拠)。
protocol PictureInPictureCapable: AnyObject {
  /// いまの再生経路の映像レイヤーから PiP コントローラを作る。読み込み中・Web表示へ切替中など
  /// ネイティブ映像が無いときは nil。
  func makePictureInPictureController() -> AVPictureInPictureController?
  /// このプレイヤーのコメント(弾幕)が流れるビュー。PiP 中はここへ流れたコメントを PiP にも流す。
  var pictureInPictureDanmakuView: UIView { get }
}

extension Notification.Name {
  /// PiP の対象配信が変わった(開始要求・開始・終了)。セルのボタン表示を更新する。
  static let multiViewPictureInPictureChanged = Notification.Name("MultiViewPictureInPictureChanged")
}

final class PictureInPictureCoordinator: NSObject, AVPictureInPictureControllerDelegate {
  static let shared = PictureInPictureCoordinator()

  /// PiP 表示中(開始処理中を含む)の配信ID。同時に PiP にできるのは 1 配信だけ。
  private(set) var activeStreamID: String?
  private var activeLabel = ""
  private var controller: AVPictureInPictureController?
  private weak var sourceDanmakuView: UIView?
  private var overlay: UIView?
  private var overlayLaneCursor = 0
  private var possibleObservation: NSKeyValueObservation?
  private var startTimeoutWork: DispatchWorkItem?
  private var onMessage: ((String) -> Void)?
  // 開始/終了のアニメーション中。この間のボタン操作は無視する(連打で窓が取り残されないように)。
  private var transitionInProgress = false
  // 開始アニメーション中に閉じる必要が生じた(配信の削除など)。開始し終えた直後に閉じる。
  private var closeAfterStart = false
  // 別の配信を PiP 中に押された場合、今の PiP が閉じ終わってから開始する。
  private var pendingStart: (() -> Void)?
  private var pendingStartFallbackWork: DispatchWorkItem?

  private override init() {
    super.init()
  }

  func isActive(streamID: String) -> Bool {
    activeStreamID == streamID
  }

  /// セルの PiP ボタン。その配信が PiP 中なら閉じ、そうでなければその配信を PiP にする。
  func toggle(streamID: String, label: String, source: PictureInPictureCapable?, onMessage: @escaping (String) -> Void) {
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
      pendingStart = { [weak self, weak source] in
        guard let self, let source else { return }
        self.start(streamID: streamID, label: label, source: source, onMessage: onMessage)
      }
      schedulePendingStartFallback()
      transitionInProgress = true
      current.stopPictureInPicture()
      return
    }
    start(streamID: streamID, label: label, source: source, onMessage: onMessage)
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

  /// NativeDanmakuRenderer.emit から呼ばれる。PiP 中の配信のコメントなら PiP の窓にも同じコメントを流す。
  func mirrorDanmaku(tokens: [NativeDanmakuToken], filterText: String, from root: UIView, settings: AppSettings, highlighted: Bool) {
    guard let overlay, root === sourceDanmakuView, overlay.window != nil,
          overlay.bounds.width > 0, overlay.bounds.height > 0 else { return }
    var pipSettings = settings
    // PiP の窓は小さい。設定の最大行数が窓に収まらないと、はみ出したレーンのコメントが見えなくなるので詰める。
    let fontSize = NativeDanmakuRenderer.scaledFontSize(base: settings.danmakuFontSize, in: overlay)
    let fittingLines = max(1, Int(overlay.bounds.height / (fontSize + 8)))
    if pipSettings.danmakuMaxLines > fittingLines {
      pipSettings.danmakuMaxLines = fittingLines
    }
    overlayLaneCursor = NativeDanmakuRenderer.emit(
      tokens: tokens,
      filterText: filterText,
      in: overlay,
      laneCursor: overlayLaneCursor,
      settings: pipSettings,
      highlighted: highlighted
    )
  }

  private func start(streamID: String, label: String, source: PictureInPictureCapable, onMessage: @escaping (String) -> Void) {
    teardown(notify: false)
    guard let pip = source.makePictureInPictureController() else {
      postChange()
      onMessage("映像の読み込み中か、この表示ではPiPにできません")
      return
    }
    pip.delegate = self
    // 複数の配信を並べるアプリなので、アプリを離れた時に勝手に PiP へ入れない(ボタンでのみ開始)。
    pip.canStartPictureInPictureAutomaticallyFromInline = false
    controller = pip
    activeStreamID = streamID
    activeLabel = label
    sourceDanmakuView = source.pictureInPictureDanmakuView
    self.onMessage = onMessage
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
    removeOverlay()
    controller?.delegate = nil
    controller = nil
    activeStreamID = nil
    activeLabel = ""
    sourceDanmakuView = nil
    onMessage = nil
    transitionInProgress = false
    closeAfterStart = false
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

  // MARK: - コメント層

  private func attachOverlay(attempt: Int) {
    guard controller != nil else { return }
    if let overlay, overlay.window != nil {
      overlay.superview?.bringSubviewToFront(overlay)
      return
    }
    guard let window = Self.findPictureInPictureWindow() else {
      if attempt < 5 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
          self?.attachOverlay(attempt: attempt + 1)
        }
      } else {
        PlaybackDiagnostics.log("PiP: コメントを重ねる窓が見つからないため映像のみ")
      }
      return
    }
    let view = PictureInPictureDanmakuOverlay(frame: window.bounds)
    window.addSubview(view)
    overlay = view
    overlayLaneCursor = 0
    PlaybackDiagnostics.log("PiP: コメント層を追加(\(NSStringFromClass(type(of: window))) \(Int(window.bounds.width))x\(Int(window.bounds.height)))")
  }

  private func removeOverlay() {
    overlay?.removeFromSuperview()
    overlay = nil
  }

  // PiP の映像を載せている窓を探す。アプリ本体の窓やキーボードの窓には絶対に重ねない。
  private static func findPictureInPictureWindow() -> UIWindow? {
    let mainWindow = (UIApplication.shared.delegate as? AppDelegate)?.window
    var windows: [UIWindow] = []
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows where !windows.contains(where: { $0 === window }) {
        windows.append(window)
      }
    }
    // シーンに属さない窓も拾う(PiP の窓がどのシーンにも属さない iOS がある)。
    for window in UIApplication.shared.windows where !windows.contains(where: { $0 === window }) {
      windows.append(window)
    }
    let candidates = windows.filter { $0 !== mainWindow && !$0.isHidden }
    if let hosted = candidates.last(where: { NSStringFromClass(type(of: $0)).contains("PGHostedWindow") }) {
      return hosted
    }
    // クラス名が将来変わった時の保険: PiP の窓はアプリの通常の窓よりずっと低いレベル(-10000000)に置かれる。
    return candidates.last { window in
      let name = NSStringFromClass(type(of: window))
      return window.windowLevel.rawValue <= -1000 && !name.contains("Keyboard") && !name.contains("TextEffects")
    }
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
      return
    }
    attachOverlay(attempt: 0)
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
    removeOverlay()
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
}

// PiP の窓に重ねる透明な弾幕レイヤー。PiP の操作(再生/閉じる)を邪魔しないよう一切タッチを受けない。
private final class PictureInPictureDanmakuOverlay: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    clipsToBounds = true
    autoresizingMask = [.flexibleWidth, .flexibleHeight]
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    nil
  }
}
