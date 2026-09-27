import AVFoundation
import UIKit
import WebKit

final class PlaybackBlockingOverlay: UIView {
  private let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private let titleLabel = UILabel()
  private let detailLabel = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isHidden = true
    isUserInteractionEnabled = true
    backgroundColor = UIColor.black.withAlphaComponent(0.2)

    panel.translatesAutoresizingMaskIntoConstraints = false
    panel.layer.cornerRadius = 14
    panel.clipsToBounds = true
    addSubview(panel)

    let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 3
    stack.translatesAutoresizingMaskIntoConstraints = false
    panel.contentView.addSubview(stack)

    titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    titleLabel.textColor = .white
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 2

    detailLabel.font = .systemFont(ofSize: 11, weight: .medium)
    detailLabel.textColor = UIColor.white.withAlphaComponent(0.72)
    detailLabel.textAlignment = .center
    detailLabel.numberOfLines = 2

    NSLayoutConstraint.activate([
      panel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      panel.centerXAnchor.constraint(equalTo: centerXAnchor),
      panel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
      panel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 10),
      stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -14),
      stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -10)
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func show(title: String, detail: String?) {
    titleLabel.text = title
    detailLabel.text = detail
    detailLabel.isHidden = detail?.isEmpty ?? true
    isHidden = false
    superview?.bringSubviewToFront(self)
  }

  func hide() {
    isHidden = true
  }
}

// 再生位置が一定時間進まない「フリーズ(ストール)」を監視し、自動で復旧コールバックを呼ぶ。
// AVPlayer は本物のエラーを出さず固まることがある(回線揺れ/ライブ端枯渇)ので、currentTime の
// 前進を見て検知する。誤検知で無駄に再読み込みしないよう、無前進12秒+復旧クールダウン20秒と保守的。
//
// automaticallyWaitsToMinimizeStalling=false のプレイヤーはバッファ枯渇で rate=0(.paused)に
// 落ちて自力では再開しないことがある。以前は .paused を「ユーザーの一時停止」とみなして監視を
// 止めていたため、この形の停止は永久に復旧しなかった。意図的な停止(音声割り込み)は
// PlaybackCoordinator.isSuspended で区別し、それ以外の .paused はまず play() で押し直し、
// それでも進まなければ停止として復旧する。回線断中は再接続しても失敗するだけなので数えない。
final class StallWatchdog {
  private weak var player: AVPlayer?
  private let onStall: () -> Void
  private let stallThreshold: TimeInterval
  private let cooldown: TimeInterval
  private var timer: Timer?
  private var lastTime: Double = -1
  private var lastProgressAt = Date()
  private var lastRecoveryAt = Date.distantPast

  init(player: AVPlayer, threshold: TimeInterval = 12, cooldown: TimeInterval = 20, onStall: @escaping () -> Void) {
    self.player = player
    self.stallThreshold = threshold
    self.cooldown = cooldown
    self.onStall = onStall
  }

  func start() {
    stop()
    lastTime = -1
    lastProgressAt = Date()
    timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      self?.tick()
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func tick() {
    guard let player, let item = player.currentItem else { return }
    if PlaybackCoordinator.shared.isSuspended || !NetworkQuality.shared.isReachable || Self.reachedEnd(item) {
      lastProgressAt = Date()
      return
    }
    let now = CMTimeGetSeconds(item.currentTime())
    if now.isFinite, now > lastTime + 0.25 {
      lastTime = now
      lastProgressAt = Date()
      return
    }
    if player.timeControlStatus == .paused {
      // 止まる意図が無いのに停止している(バッファ枯渇後に自動再開しない)。押し直す。
      player.play()
    }
    guard Date().timeIntervalSince(lastProgressAt) > stallThreshold,
          Date().timeIntervalSince(lastRecoveryAt) > cooldown else { return }
    lastRecoveryAt = Date()
    lastProgressAt = Date()
    onStall()
  }

  // VOD が最後まで再生し終えた状態は停止ではない。
  private static func reachedEnd(_ item: AVPlayerItem) -> Bool {
    let duration = CMTimeGetSeconds(item.duration)
    guard duration.isFinite, duration > 0 else { return false }
    return CMTimeGetSeconds(item.currentTime()) >= duration - 1
  }
}

// Amazon IVS プレイヤー用の停止監視。IVS は .buffering/リバッファ/エラーは通知するが、
// .playing のまま映像位置が進まなくなる凍結は通知されず、AVPlayer 用の StallWatchdog も
// IVS 再生中は何も監視していなかった。position の前進を見て同じ基準で検知する。
final class IvsStallWatchdog {
  private let isPlaying: () -> Bool
  private let position: () -> CMTime?
  private let onStall: () -> Void
  private var timer: Timer?
  private var lastTime: Double = -1
  private var lastProgressAt = Date()
  private var lastRecoveryAt = Date.distantPast

  init(isPlaying: @escaping () -> Bool, position: @escaping () -> CMTime?, onStall: @escaping () -> Void) {
    self.isPlaying = isPlaying
    self.position = position
    self.onStall = onStall
  }

  deinit {
    timer?.invalidate()
  }

  func start() {
    stop()
    lastTime = -1
    lastProgressAt = Date()
    timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      self?.tick()
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func tick() {
    guard isPlaying(), !PlaybackCoordinator.shared.isSuspended, NetworkQuality.shared.isReachable,
          let time = position() else {
      lastProgressAt = Date()
      return
    }
    let now = CMTimeGetSeconds(time)
    if now.isFinite, now > lastTime + 0.25 {
      lastTime = now
      lastProgressAt = Date()
      return
    }
    guard Date().timeIntervalSince(lastProgressAt) > 12,
          Date().timeIntervalSince(lastRecoveryAt) > 20 else { return }
    lastRecoveryAt = Date()
    lastProgressAt = Date()
    onStall()
  }
}

final class NativeRetryLimiter {
  let maxAttempts: Int
  private(set) var attempts = 0
  private var pendingRetry: DispatchWorkItem?

  init(maxAttempts: Int = 2) {
    self.maxAttempts = maxAttempts
  }

  // 成功時(=予約中の再試行はもう不要)にも呼ばれるので、予約も取り消す。
  func reset() {
    attempts = 0
    cancelPending()
  }

  func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
    cancelPending()
    let item = DispatchWorkItem(block: work)
    pendingRetry = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  func cancelPending() {
    pendingRetry?.cancel()
    pendingRetry = nil
  }

  func nextAttempt() -> Int? {
    guard attempts < maxAttempts else { return nil }
    attempts += 1
    return attempts
  }
}

enum LiveEdgeCatchUp {
  static func seekIfNeeded(
    player: AVPlayer,
    isStopped: Bool,
    fallbackActive: Bool,
    behindThreshold: TimeInterval = 6,
    targetOffset: TimeInterval = 3,
    toleranceBefore: TimeInterval = 1
  ) {
    guard !isStopped, !fallbackActive,
          player.timeControlStatus == .playing,
          let item = player.currentItem,
          let liveRange = item.seekableTimeRanges.last?.timeRangeValue,
          liveRange.duration.isNumeric else { return }
    let liveEdge = CMTimeAdd(liveRange.start, liveRange.duration)
    let current = item.currentTime()
    let behind = CMTimeGetSeconds(CMTimeSubtract(liveEdge, current))
    guard behind > behindThreshold else { return }
    let target = CMTimeSubtract(liveEdge, CMTime(seconds: targetOffset, preferredTimescale: 600))
    guard CMTimeCompare(target, current) > 0 else { return }
    item.seek(to: target,
              toleranceBefore: CMTime(seconds: toleranceBefore, preferredTimescale: 600),
              toleranceAfter: .zero) { _ in }
  }
}

enum NativeAVPlaybackCleanup {
  static func run(
    player: AVPlayer,
    playerLayer: AVPlayerLayer,
    liveCatchUpTimer: inout Timer?,
    stallWatchdog: StallWatchdog,
    itemStatusObservation: inout NSKeyValueObservation?,
    itemFailedObserver: inout NSObjectProtocol?
  ) {
    liveCatchUpTimer?.invalidate()
    liveCatchUpTimer = nil
    stallWatchdog.stop()
    itemStatusObservation = nil
    if let observer = itemFailedObserver {
      NotificationCenter.default.removeObserver(observer)
      itemFailedObserver = nil
    }
    player.pause()
    player.replaceCurrentItem(with: nil)
    playerLayer.isHidden = false
  }
}

enum NativeFallbackRetry {
  // 再試行の間隔。以前は即時に2回使い切ってWeb UIへ落ちていたため、瞬間的なCDN/トークンの
  // 不調でもネイティブ再生を失っていた。
  static func retryDelay(forAttempt attempt: Int) -> TimeInterval {
    attempt <= 1 ? 1.5 : 5
  }

  static func retryOrFallback(
    isStopped: Bool,
    fallbackActive: Bool,
    generation: Int? = nil,
    currentGeneration: Int,
    limiter: NativeRetryLimiter,
    teardown: () -> Void,
    cancelRequest: () -> Void,
    resetLoading: () -> Void,
    showRetry: (Int) -> Void,
    waitForNetwork: () -> Void,
    reload: @escaping () -> Void,
    fallback: () -> Void
  ) {
    guard !isStopped, !fallbackActive else { return }
    if let generation, generation != currentGeneration { return }
    if !NetworkQuality.shared.isReachable {
      // 回線断中の失敗は回線のせい。試行回数を消費せず(=Web UIへ落とさず)回線復帰を待つ。
      // 復帰時は視聴タブが .multiViewNetworkRestored でこのセルを作り直す。
      limiter.cancelPending()
      teardown()
      cancelRequest()
      resetLoading()
      waitForNetwork()
      return
    }
    if let attempt = limiter.nextAttempt() {
      teardown()
      cancelRequest()
      resetLoading()
      showRetry(attempt)
      limiter.schedule(after: retryDelay(forAttempt: attempt), reload)
      return
    }
    fallback()
  }
}

// Twitch の公開 web クライアント ID(GQL 用)。TwitchPlayer(再生トークン取得)と
// ViewerCount(同接数取得)の両方で使うため、一箇所で管理する。
enum TwitchGQL {
  static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
}

// WKUserContentController retains its script message handlers strongly, so passing
// a view/controller itself to `add(_:name:)` creates the classic retain cycle
// (controller → handler → webView → controller) that keeps the owner alive and
// prevents deinit from running. This proxy holds the real handler weakly and
// forwards messages transparently (same handler names, same messages).
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  private weak var delegate: WKScriptMessageHandler?

  init(delegate: WKScriptMessageHandler) {
    self.delegate = delegate
    super.init()
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    delegate?.userContentController(userContentController, didReceive: message)
  }
}

extension WKWebView {
  func playAllMedia() {
    evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(m){try{m.play()}catch(e){}});")
  }

  func pauseAllMedia() {
    evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(m){try{m.pause()}catch(e){}});")
  }

  func setAllMediaVolume(_ volume: Float, muted: Bool) {
    let volumeLiteral = String(Double(min(1, max(0, volume))))
    let mutedLiteral = muted ? "true" : "false"
    evaluateJavaScript(
      "document.querySelectorAll('video,audio').forEach(function(m){try{m.volume=\(volumeLiteral);m.muted=\(mutedLiteral);}catch(e){}});"
    )
  }

  func stopLoadingAndRemove() {
    stopLoading()
    loadHTMLString("", baseURL: nil)
    removeFromSuperview()
  }
}
