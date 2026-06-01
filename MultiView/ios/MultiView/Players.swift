import UIKit
import WebKit
import AVFoundation
import Network
import ImageIO
import AuthenticationServices
import Security
import CryptoKit

// Per-platform native player views (Niconico / Kick / Twitch / TwitCasting / YouTube).
// Each plays its stream via a dedicated AVPlayer/WebView. Extracted from AppDelegate.swift.

// 再生位置が一定時間進まない「フリーズ(ストール)」を監視し、自動で復旧コールバックを呼ぶ。
// AVPlayer は本物のエラーを出さず固まることがある(回線揺れ/ライブ端枯渇)ので、currentTime の
// 前進を見て検知する。誤検知で無駄に再読み込みしないよう、無前進12秒+復旧クールダウン20秒と保守的。
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
    if player.timeControlStatus == .paused {
      lastProgressAt = Date()
      return
    }
    let now = CMTimeGetSeconds(item.currentTime())
    if now.isFinite, now > lastTime + 0.25 {
      lastTime = now
      lastProgressAt = Date()
      return
    }
    guard Date().timeIntervalSince(lastProgressAt) > stallThreshold,
          Date().timeIntervalSince(lastRecoveryAt) > cooldown else { return }
    lastRecoveryAt = Date()
    lastProgressAt = Date()
    onStall()
  }
}

final class NativeRetryLimiter {
  let maxAttempts: Int
  private(set) var attempts = 0

  init(maxAttempts: Int = 2) {
    self.maxAttempts = maxAttempts
  }

  func reset() {
    attempts = 0
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

final class NiconicoNativePlayerView: UIView, PlaybackResumable, PlaybackStoppable, AudioControllable, CommentPostable, CommentEchoDisplay {
  private let stream: StreamItem
  private let player = AVPlayer()
  private let playerLayer = AVPlayerLayer()
  private let danmakuView = UIView()
  private let statusLabel = UILabel()
  private var pageTask: URLSessionDataTask?
  private var socketTask: URLSessionWebSocketTask?
  private var ndgrCommentTask: Task<Void, Never>?
  private var segmentTasks: [String: Task<Void, Never>] = [:]
  private var activeSegmentURIs = Set<String>()
  private var keepSeatTimer: Timer?
  private var endRemovalWorkItem: DispatchWorkItem?
  private var endCountdownTimer: Timer?
  private var endCountdownRemaining = 0
  private var itemStatusObservation: NSKeyValueObservation?
  private var itemFailedObserver: NSObjectProtocol?
  private var fallbackWebView: PlayerWebView?
  private let settings: AppSettings
  private let channel: String
  private var playbackVolume: Float
  private var isLoading = false
  private var isStopped = false
  private var watchPageURL: URL?
  private var laneCursor = 0
  private var loadAttempts = 0
  private var streamOpenedAt: Date?
  private var isEnding = false
  private var lastSupportAlert: (text: String, at: Date)?
  private var seenSupportEventIDs = Set<String>()
  // NDGR コメントが最後に成功した時刻。VIEW/SEGMENT 両方のループから更新され、
  // 60 秒成功なしでフル再読み込みへ escalation する閾値判定に使う。
  private var ndgrLastSuccessAt = Date()
  private var ndgrReconnectStartedAt: Date?
  private lazy var stallWatchdog = StallWatchdog(player: player) { [weak self] in
    self?.recoverPlaybackError("再生が止まったため再接続中")
  }

  private struct NiconicoGiftBarUpdate {
    let currentLevel: Int?
    let nextLevelRewardCount: Int?
    let remainingPointsForNextLevel: Int?
    let requiredPointsForNextLevel: Int?

    var progress: CGFloat? {
      guard let requiredPointsForNextLevel, requiredPointsForNextLevel > 0,
            let remainingPointsForNextLevel else { return nil }
      let completed = max(0, requiredPointsForNextLevel - remainingPointsForNextLevel)
      return CGFloat(min(completed, requiredPointsForNextLevel)) / CGFloat(requiredPointsForNextLevel)
    }

    var summary: String? {
      var parts: [String] = []
      if let currentLevel {
        parts.append("ギフトLv\(currentLevel)")
      }
      if let remainingPointsForNextLevel, remainingPointsForNextLevel > 0 {
        parts.append("次まで\(remainingPointsForNextLevel)pt")
      }
      if let nextLevelRewardCount, nextLevelRewardCount > 0 {
        parts.append("報酬\(nextLevelRewardCount)")
      }
      return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }
  }

  private struct NiconicoSupportEvent {
    enum Kind {
      case gift
      case nicoad
      case notification
      case akashic
    }

    let id: String?
    let kind: Kind
    let title: String
    let subtitle: String?
    let giftBar: NiconicoGiftBarUpdate?
    let effectStyle: NativeGiftEffectStyle
    let assetURL: URL?

    var symbolName: String {
      effectStyle.heroSymbol
    }
  }

  init(stream: StreamItem, settings: AppSettings) {
    self.stream = stream
    self.settings = settings
    self.channel = stream.channel
    self.playbackVolume = StreamVolumeStore.volume(for: stream)
    super.init(frame: .zero)
    backgroundColor = .black
    NiconicoGiftEffectCache.shared.prewarmCommonEffects()

    // ニコ生は automaticallyWaitsToMinimizeStalling=false (常時ライブエッジ) だと回線の
    // 揺れで頻繁にストールし、フレームレートがガクガク＋「見られるまで遅い」になっていた
    // (ce716c1 の低遅延化で発生)。低遅延よりも滑らかさを優先し、AVPlayer にバッファ管理を
    // 任せる (true)。他プラットフォームは挙動が安定しているため false のまま据え置く。
    // 既定は true(滑らか優先)。設定「ニコ生 低遅延」を ON にするとユーザー責任で false(低遅延)。
    player.automaticallyWaitsToMinimizeStalling = !settings.niconicoLowLatency
    playerLayer.player = player
    playerLayer.videoGravity = .resizeAspect
    player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    layer.addSublayer(playerLayer)

    danmakuView.isUserInteractionEnabled = false
    danmakuView.clipsToBounds = true
    addSubview(danmakuView)

    statusLabel.text = "ニコ生を読み込み中"
    statusLabel.textColor = .white.withAlphaComponent(0.72)
    statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
    statusLabel.textAlignment = .center
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(statusLabel)
    NSLayoutConstraint.activate([
      statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
    ])

    PlaybackCoordinator.shared.register(self)
    load(channel: stream.channel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    stopPlayback()
  }

  func stopPlayback() {
    isStopped = true
    stallWatchdog.stop()
    player.pause()
    player.replaceCurrentItem(with: nil)
    keepSeatTimer?.invalidate()
    keepSeatTimer = nil
    endRemovalWorkItem?.cancel()
    endRemovalWorkItem = nil
    endCountdownTimer?.invalidate()
    endCountdownTimer = nil
    endCountdownRemaining = 0
    ndgrCommentTask?.cancel()
    ndgrCommentTask = nil
    ndgrReconnectStartedAt = nil
    segmentTasks.values.forEach { $0.cancel() }
    segmentTasks.removeAll()
    activeSegmentURIs.removeAll()
    pageTask?.cancel()
    pageTask = nil
    socketTask?.cancel(with: .goingAway, reason: nil)
    socketTask = nil
    fallbackWebView?.stopPlayback()
    fallbackWebView?.removeFromSuperview()
    fallbackWebView = nil
    itemStatusObservation = nil
    if let itemFailedObserver {
      NotificationCenter.default.removeObserver(itemFailedObserver)
      self.itemFailedObserver = nil
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    playerLayer.frame = bounds
    danmakuView.frame = bounds
  }

  func resumePlayback() {
    guard !isStopped else { return }
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default, options: [])
    try? session.setActive(true)
    if let fallbackWebView {
      fallbackWebView.resumePlayback()
      return
    }
    if player.currentItem == nil {
      if isLoading || socketTask != nil {
        return
      }
      load(channel: channel)
      return
    }
    player.isMuted = !settings.playAudio
    player.volume = settings.playAudio ? playbackVolume : 0
    player.play()
  }

  func pausePlayback() {
    player.pause()
    fallbackWebView?.pausePlayback()
  }

  func setPlaybackVolume(_ volume: Float) {
    playbackVolume = min(1, max(0, volume))
    player.volume = settings.playAudio ? playbackVolume : 0
    fallbackWebView?.setPlaybackVolume(playbackVolume)
  }

  func postComment(_ text: String, completion: @escaping (Result<Void, Error>) -> Void) {
    let programId = channel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !programId.isEmpty else {
      completion(.failure(NSError(domain: "Niconico", code: -1, userInfo: [NSLocalizedDescriptionKey: "番組IDが不正です"])))
      return
    }
    guard let cookieURL = URL(string: "https://live.nicovideo.jp/"),
          let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL),
          cookies.contains(where: { $0.name == "user_session" }) else {
      completion(.failure(NSError(domain: "Niconico", code: 401, userInfo: [NSLocalizedDescriptionKey: "ニコ生にログインしてください"])))
      return
    }
    guard let socketTask else {
      completion(.failure(NSError(domain: "Niconico", code: 409, userInfo: [NSLocalizedDescriptionKey: "ニコ生のコメント接続がまだ準備できていません。再読み込み後にもう一度試してください。"])))
      return
    }
    let elapsed = streamOpenedAt.map { Date().timeIntervalSince($0) } ?? 0
    let vpos = max(0, Int(elapsed * 100))
    let payload: [String: Any] = [
      "type": "postComment",
      "data": [
        "text": text,
        "vpos": vpos
      ]
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let json = String(data: data, encoding: .utf8) else {
      completion(.failure(NSError(domain: "Niconico", code: -2, userInfo: [NSLocalizedDescriptionKey: "コメント内容を送信形式に変換できません"])))
      return
    }
    socketTask.send(.string(json)) { error in
      DispatchQueue.main.async {
        if let error {
          completion(.failure(error))
          return
        }
        completion(.success(()))
      }
    }
  }

  private func load(channel: String) {
    guard !isStopped else { return }
    guard !isLoading else { return }
    guard fallbackWebView == nil else { return }
    let programId = channel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: "https://live.nicovideo.jp/watch/\(programId)") else {
      installFallback("番組IDが不正です")
      return
    }
    watchPageURL = url
    isLoading = true
    showStatus(loadAttempts == 0 ? "ニコ生セッションを準備中" : "ニコ生再試行中… (\(loadAttempts))")
    WebLoginCookies.restore { [weak self] in
      guard let self, !self.isStopped else { return }
      NiconicoWarmup.shared.prewarm(programId: programId, forceReload: self.loadAttempts > 0) { [weak self] in
        guard let self, !self.isStopped else { return }
        self.syncNiconicoWebCookies { [weak self] in
          guard let self else { return }
          self.prewarmNiconicoGiftAssets()
          self.fetchWatchPage(url: url)
        }
      }
    }
  }

  // The first attempt right after a web login often runs before the login cookies
  // have propagated to the native jar, so transient failures retry the whole load
  // (re-syncing cookies) a couple of times before giving up to the web fallback —
  // this removes the "expand once and come back" workaround.
  private func retryOrFallback(_ reason: String) {
    guard !isStopped, !isEnding, fallbackWebView == nil else { return }
    verifyProgramEndedFromPage { [weak self] ended in
      guard let self, !self.isStopped, self.fallbackWebView == nil else { return }
      if ended {
        self.beginEndedCountdown("番組が終了しましたので閉じます")
        return
      }
      self.continueRetryOrFallback(reason)
    }
  }

  private func continueRetryOrFallback(_ reason: String) {
    loadAttempts += 1
    guard loadAttempts <= 4 else {
      showStatus("\(reason)\n再読み込みします")
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .multiViewPlaybackErrored, object: nil)
      }
      return
    }
    showStatus("ニコ生再試行中… (\(loadAttempts))")
    socketTask?.cancel(with: .goingAway, reason: nil)
    socketTask = nil
    isLoading = false
    let delay = Double(loadAttempts)
    WebLoginCookies.restore { [weak self] in
      guard let self, !self.isStopped else { return }
      NiconicoWarmup.shared.prewarm(programId: self.channel, forceReload: true) { [weak self] in
        guard let self, !self.isStopped else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
          self.load(channel: self.channel)
        }
      }
    }
  }

  private func fetchWatchPage(url: URL) {
    guard !isStopped else { return }
    var request = URLRequest(url: url)
    Self.mobileBrowserHeaders(referer: "https://live.nicovideo.jp/").forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    pageTask = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
      guard let self else { return }
      self.pageTask = nil
      self.isLoading = false
      if let error {
        self.retryOrFallback("ニコ生ページ取得失敗: \(error.localizedDescription)")
        return
      }
      guard let data, let html = String(data: data, encoding: .utf8) else {
        self.retryOrFallback("ニコ生ページを読めません")
        return
      }
      do {
        if Self.isEndedWatchPage(html) {
          self.beginEndedCountdown("番組が終了しましたので閉じます")
          return
        }
        let watch = try self.parseWatchData(from: html)
        self.scheduleProgramEndIfNeeded(watch.endDate)
        self.connect(webSocketURL: watch.webSocketURL, frontendId: watch.frontendId)
      } catch {
        if Self.isEndedWatchPage(html) {
          self.beginEndedCountdown("番組が終了しましたので閉じます")
          return
        }
        self.retryOrFallback("ニコ生の再生情報を取得できません")
      }
    }
    pageTask?.resume()
  }

  private func connect(webSocketURL: URL, frontendId: String?) {
    var components = URLComponents(url: webSocketURL, resolvingAgainstBaseURL: false)
    var items = components?.queryItems ?? []
    if let frontendId, !items.contains(where: { $0.name == "frontend_id" }) {
      items.append(URLQueryItem(name: "frontend_id", value: frontendId))
      components?.queryItems = items
    }
    guard let url = components?.url else {
      installFallback("ニコ生WebSocket URLが不正です")
      return
    }
    var request = URLRequest(url: url)
    Self.mobileBrowserHeaders(referer: watchPageURL?.absoluteString ?? "https://live.nicovideo.jp/").forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    request.setValue("https://live.nicovideo.jp", forHTTPHeaderField: "Origin")
    let socket = URLSession.shared.webSocketTask(with: request)
    socketTask = socket
    socket.resume()
    receiveNext()
    sendStartWatching()
  }

  private func sendStartWatching() {
    let payload: [String: Any] = [
      "type": "startWatching",
      "data": [
        "stream": [
          "quality": NetworkQuality.shared.activeQuality(settings: settings).niconicoQuality,
          "protocol": "hls",
          "latency": "low",
          "requireNewStream": true,
          "accessRightMethod": "single_cookie",
          "chasePlay": false
        ],
        "room": [
          "protocol": "webSocket",
          "commentable": true
        ],
        "reconnect": false
      ]
    ]
    send(payload)
  }

  private func send(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let text = String(data: data, encoding: .utf8) else { return }
    socketTask?.send(.string(text)) { _ in }
  }

  private func receiveNext() {
    socketTask?.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let message):
        switch message {
        case .string(let text):
          self.handleSocketText(text)
        case .data(let data):
          if let text = String(data: data, encoding: .utf8) {
            self.handleSocketText(text)
          }
        @unknown default:
          break
        }
        self.receiveNext()
      case .failure(let error):
        if self.isEnding { return }
        self.socketTask = nil
        if self.player.currentItem == nil {
          self.retryOrFallback("ニコ生WebSocket切断: \(error.localizedDescription)")
          return
        }
        self.showStatus("ニコ生WebSocket再接続中: \(error.localizedDescription)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
          guard let self, !self.isStopped else { return }
          self.load(channel: self.channel)
        }
      }
    }
  }

  private func handleSocketText(_ text: String) {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String else { return }
    if type == "ping" {
      send(["type": "pong"])
      return
    }
    if type == "seat",
       let payload = json["data"] as? [String: Any],
       let interval = payload["keepIntervalSec"] as? TimeInterval {
      startKeepSeatTimer(interval: interval)
      return
    }
    if type == "messageServer",
       let payload = json["data"] as? [String: Any],
       let viewURI = payload["viewUri"] as? String,
       !viewURI.isEmpty {
      startNDGRComments(viewURI: viewURI)
      return
    }
    if type == "stream",
       let payload = json["data"] as? [String: Any],
       let uriString = payload["uri"] as? String,
       let uri = URL(string: uriString) {
      loadAttempts = 0
      if streamOpenedAt == nil { streamOpenedAt = Date() }
      let cookies = parseStreamCookies(payload["cookies"], for: uri)
      applyNiconicoCookies(cookies)
      play(hlsURL: uri, cookies: cookies)
    }
    if type == "error",
       let payload = json["data"] as? [String: Any],
       let code = payload["code"] as? String {
      let lower = code.lowercased()
      if lower.contains("permission") || lower.contains("resource") || lower.contains("auth") || lower.contains("login") || lower.contains("denied") {
        // Usually a just-completed web login whose cookies have not reached the
        // native jar yet — re-sync and retry the whole load before falling back.
        retryOrFallback("ニコ生エラー: \(code)")
      } else if player.currentItem == nil {
        retryOrFallback("ニコ生エラー: \(code)")
      } else {
        showStatus("ニコ生エラー: \(code)")
      }
    }
    if type == "disconnect" {
      if let payload = json["data"] as? [String: Any],
         Self.isProgramEndedPayload(payload) {
        beginEndedCountdown("番組が終了しましたので閉じます")
        return
      }
      socketTask = nil
      if player.currentItem == nil {
        installFallback("ニコ生から切断されました")
        return
      }
      showStatus("ニコ生へ再接続中")
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
        guard let self, !self.isStopped else { return }
        self.load(channel: self.channel)
      }
    }
  }

  private func scheduleProgramEndIfNeeded(_ endDate: Date?) {
    endRemovalWorkItem?.cancel()
    endRemovalWorkItem = nil
    // Niconico end timestamps and disconnect payloads can be noisy. Do not
    // schedule automatic removal; leave the cell under the user's control.
    _ = endDate
  }

  private func beginEndedCountdown(_ reason: String) {
    DispatchQueue.main.async {
      guard !self.isStopped else { return }
      self.endRemovalWorkItem?.cancel()
      self.endRemovalWorkItem = nil
      self.endCountdownTimer?.invalidate()
      self.endCountdownTimer = nil
      self.endCountdownRemaining = 0
      let message = reason
        .replacingOccurrences(of: "ので閉じます", with: "")
        .replacingOccurrences(of: "閉じます", with: "")
      self.showStatus("\(message)\n自動では閉じません")
    }
  }

  private func removeEndedProgram(_ reason: String) {
    DispatchQueue.main.async {
      guard !self.isStopped else { return }
      self.showStatus("\(reason)\n自動削除は無効です")
    }
  }

  // 番組終了の disconnect payload は具体的な code を持つ。
  // 旧実装は payload 全文を flatten して "end" を contains していたので、
  // 例えば "endpoint" や "send" 等のごく普通の単語が含まれただけで誤発火していた。
  // ニコ生公式 WebSocket の END_PROGRAM 系コード (END_PROGRAM / PROGRAM_END /
  // BROADCAST_ENDED / FINISHED) と、disconnect の reason フィールドに明示的に
  // ENDED 系の語が単体で出ているケースのみを終了とみなす。
  private static func isProgramEndedPayload(_ payload: [String: Any]) -> Bool {
    let codeFields = [payload["code"], payload["reason"], payload["type"]]
      .compactMap { $0 as? String }
      .map { $0.uppercased() }
    let endedCodes: Set<String> = [
      "END_PROGRAM",
      "PROGRAM_END",
      "PROGRAM_ENDED",
      "ENDED",
      "BROADCAST_ENDED",
      "FINISHED",
      "END_ENTERTAINMENT"
    ]
    if codeFields.contains(where: { endedCodes.contains($0) }) {
      return true
    }
    // data.programEnded == true のような明示フラグも認める
    if (payload["programEnded"] as? Bool) == true { return true }
    if (payload["ended"] as? Bool) == true { return true }
    return false
  }

  private func verifyProgramEndedFromPage(completion: @escaping (Bool) -> Void) {
    guard let watchPageURL else {
      completion(false)
      return
    }
    var request = URLRequest(url: watchPageURL)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    Self.mobileBrowserHeaders(referer: "https://live.nicovideo.jp/").forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    URLSession.shared.dataTask(with: request) { data, _, _ in
      let html = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      DispatchQueue.main.async {
        completion(Self.isEndedWatchPage(html))
      }
    }.resume()
  }

  // 旧実装は HTML 全文に「次回の放送をリクエストしませんか」等を contains
  // 検査していたが、これらはフッター・サイドバー・チャンネル詳細にも出現する
  // ため、生きてる番組でも常時 true になり、誤って閉鎖していた。
  // 番組情報 JSON (initial-state / embedded-data の data-props) の中の
  // "status":"ENDED" / "state":"ENDED" / "endTime" 経過、の明示シグナルだけを採用。
  private static func isEndedWatchPage(_ html: String) -> Bool {
    let entityEnded = html.range(of: #"&quot;(status|state)&quot;\s*:\s*&quot;ENDED&quot;"#, options: .regularExpression)
    if entityEnded != nil { return true }
    let plainEnded = html.range(of: #""(status|state)"\s*:\s*"ENDED""#, options: .regularExpression)
    if plainEnded != nil { return true }
    if html.contains(#"data-program-status="ENDED""#) { return true }
    if html.contains(#"&quot;programStatus&quot;:&quot;ENDED&quot;"#) { return true }
    return false
  }

  private func startKeepSeatTimer(interval: TimeInterval) {
    DispatchQueue.main.async {
      self.keepSeatTimer?.invalidate()
      self.keepSeatTimer = Timer.scheduledTimer(withTimeInterval: max(5, interval), repeats: true) { [weak self] _ in
        self?.send(["type": "keepSeat"])
      }
      self.send(["type": "keepSeat"])
    }
  }

  private func play(hlsURL: URL, cookies: [HTTPCookie] = []) {
    DispatchQueue.main.async {
      guard !self.isStopped else { return }
      self.statusLabel.isHidden = true
      var assetOptions: [String: Any] = [
        "AVURLAssetHTTPHeaderFieldsKey": self.niconicoPlaybackHeaders(),
        // Live HLS never needs a precise duration; skipping that analysis trims a
        // little startup work (Apple notes precise duration can be costly).
        AVURLAssetPreferPreciseDurationAndTimingKey: false
      ]
      if !cookies.isEmpty {
        assetOptions[AVURLAssetHTTPCookiesKey] = cookies
      }
      let asset = AVURLAsset(url: hlsURL, options: assetOptions)
      let item = AVPlayerItem(asset: asset)
      item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
      item.preferredPeakBitRate = NetworkQuality.shared.effectivePeakBitRate(settings: self.settings)
      // LL-HLS 配信時のみライブエッジから一定位置を狙う(通常HLSはno-op)。設定「ニコ生 低遅延」
      // ON で 4→1.5 秒に詰める(LL-HLS配信なら遅延が縮む。通常HLSなら効かないのでローダーが別途必要)。
      // 低遅延ONで1.5秒(再詰め)。OFFは従来4s。
      item.configuredTimeOffsetFromLive = self.settings.niconicoLowLatency
        ? CMTime(seconds: 1.0, preferredTimescale: 600)
        : CMTime(seconds: 4, preferredTimescale: 1)
      item.automaticallyPreservesTimeOffsetFromLive = true
      self.itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
        if item.status == .failed {
          DispatchQueue.main.async {
            self?.recoverPlaybackError(item.error?.localizedDescription ?? "ニコ生の再生に失敗しました")
          }
        }
      }
      if let itemFailedObserver = self.itemFailedObserver {
        NotificationCenter.default.removeObserver(itemFailedObserver)
      }
      self.itemFailedObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemFailedToPlayToEndTime,
        object: item,
        queue: .main
      ) { [weak self] notification in
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
        self?.recoverPlaybackError(error?.localizedDescription ?? "ニコ生の再生が停止しました")
      }
      self.player.replaceCurrentItem(with: item)
      self.player.isMuted = !self.settings.playAudio
      self.player.volume = self.settings.playAudio ? self.playbackVolume : 0
      self.player.play()
      self.stallWatchdog.start()
    }
  }

  private func recoverPlaybackError(_ reason: String) {
    guard !isStopped, !isEnding else { return }
    showStatus("\(reason)\n自動復旧中")
    player.pause()
    player.replaceCurrentItem(with: nil)
    retryOrFallback(reason)
  }

  private func niconicoPlaybackHeaders() -> [String: String] {
    var headers = Self.mobileBrowserHeaders(referer: watchPageURL?.absoluteString ?? "https://live.nicovideo.jp/")
    headers["Origin"] = "https://live.nicovideo.jp"
    let cookieURL = URL(string: "https://live.nicovideo.jp/")!
    if let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL), !cookies.isEmpty {
      headers["Cookie"] = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    return headers
  }

  private func prewarmNiconicoGiftAssets() {
    NiconicoGiftEffectCache.shared.prewarmGiftionaryAPI(headers: niconicoGiftAPIHeaders())
  }

  private func niconicoGiftAPIHeaders() -> [String: String] {
    var headers: [String: String] = [
      "Accept": "application/json",
      "Referer": "https://gift.nicovideo.jp/giftionary",
      "Origin": "https://gift.nicovideo.jp",
      "User-Agent": Self.userAgent,
      "X-Frontend-Id": "148",
      "X-Frontend-Version": "1.1.58"
    ]
    if let cookieHeader = niconicoCookieHeader() {
      headers["Cookie"] = cookieHeader
    }
    return headers
  }

  private func niconicoCookieHeader() -> String? {
    let cookies = (HTTPCookieStorage.shared.cookies ?? [])
      .filter { cookie in
        let domain = cookie.domain.lowercased()
        return domain.contains("nicovideo.jp") || domain.contains("nimg.jp")
      }
    guard !cookies.isEmpty else { return nil }
    return cookies
      .map { "\($0.name)=\($0.value)" }
      .joined(separator: "; ")
  }

  private static func mobileBrowserHeaders(referer: String) -> [String: String] {
    var headers = [
      "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6",
      "User-Agent": NiconicoNativePlayerView.userAgent,
      "Referer": referer
    ]
    // Send the user's niconico login cookies. Many programs now require login, and
    // an anonymous startWatching returns a permission error.
    if let url = URL(string: "https://live.nicovideo.jp/"),
       let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty {
      headers["Cookie"] = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    return headers
  }

  private func syncNiconicoWebCookies(_ completion: @escaping () -> Void) {
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
      cookies
        .filter { $0.domain.contains("nicovideo.jp") || $0.domain.contains("nimg.jp") }
        .forEach { HTTPCookieStorage.shared.setCookie($0) }
      DispatchQueue.main.async(execute: completion)
    }
  }

  private func parseStreamCookies(_ raw: Any?, for url: URL) -> [HTTPCookie] {
    guard let array = raw as? [[String: Any]] else { return [] }
    return array.compactMap { dict -> HTTPCookie? in
      guard let name = dict["name"] as? String,
            let value = dict["value"] as? String else { return nil }
      var props: [HTTPCookiePropertyKey: Any] = [
        .name: name,
        .value: value,
        .path: (dict["path"] as? String) ?? "/"
      ]
      if let domain = dict["domain"] as? String, !domain.isEmpty {
        props[.domain] = domain
      } else if let host = url.host {
        props[.domain] = host
      }
      if let secure = dict["secure"] as? Bool, secure {
        props[.secure] = "TRUE"
      }
      if let expire = dict["expireTime"] as? Double {
        props[.expires] = Date(timeIntervalSince1970: expire)
      } else if let maxAgeString = dict["maxAge"] as? String, let maxAge = Double(maxAgeString) {
        props[.expires] = Date(timeIntervalSinceNow: maxAge)
      } else if let maxAge = dict["maxAge"] as? Double {
        props[.expires] = Date(timeIntervalSinceNow: maxAge)
      }
      return HTTPCookie(properties: props)
    }
  }

  private func applyNiconicoCookies(_ cookies: [HTTPCookie]) {
    cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }
  }

  private func installFallback(_ reason: String) {
    DispatchQueue.main.async {
      guard !self.isStopped, self.fallbackWebView == nil else { return }
      self.stallWatchdog.stop()
      self.showStatus(reason)
      self.player.pause()
      self.player.replaceCurrentItem(with: nil)
      self.keepSeatTimer?.invalidate()
      self.keepSeatTimer = nil
      self.socketTask?.cancel(with: .goingAway, reason: nil)
      self.socketTask = nil
      self.ndgrCommentTask?.cancel()
      self.ndgrCommentTask = nil
      self.segmentTasks.values.forEach { $0.cancel() }
      self.segmentTasks.removeAll()
      self.activeSegmentURIs.removeAll()
      self.statusLabel.isHidden = true
      let web = PlayerWebView(stream: self.stream, settings: self.settings)
      web.setPlaybackVolume(self.playbackVolume)
      web.translatesAutoresizingMaskIntoConstraints = false
      self.insertSubview(web, belowSubview: self.danmakuView)
      NSLayoutConstraint.activate([
        web.topAnchor.constraint(equalTo: self.topAnchor),
        web.leadingAnchor.constraint(equalTo: self.leadingAnchor),
        web.trailingAnchor.constraint(equalTo: self.trailingAnchor),
        web.bottomAnchor.constraint(equalTo: self.bottomAnchor)
      ])
      self.fallbackWebView = web
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        web.resumePlayback()
      }
    }
  }

  private func startNDGRComments(viewURI: String) {
    guard settings.showChat else { return }
    ndgrCommentTask?.cancel()
    segmentTasks.values.forEach { $0.cancel() }
    segmentTasks.removeAll()
    activeSegmentURIs.removeAll()
    ndgrLastSuccessAt = Date()
    ndgrReconnectStartedAt = nil
    ndgrCommentTask = Task { [weak self] in
      guard let self else { return }
      await self.streamNDGRView(viewURI: viewURI)
    }
  }

  // VIEW ストリーム: セグメント URI と nextAt をポーリングする長期接続。
  // 切断時は in-place 再接続し、コメント取得だけが詰まった状態を長く残さない。
  private func streamNDGRView(viewURI: String) async {
    var nextAt: String? = "now"
    var consecutiveFailures = 0
    while !Task.isCancelled {
      let requestAt = nextAt
      guard var components = URLComponents(string: viewURI) else { return }
      if let requestAt {
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "at", value: requestAt))
        components.queryItems = items
      }
      guard let url = components.url else { return }
      nextAt = nil
      do {
        var receivedMessage = false
        for try await message in protobufMessages(from: url, timeoutInterval: 12) {
          if consecutiveFailures > 0 {
            clearNDGRReconnectStatus()
          }
          receivedMessage = true
          if let segmentURI = parseNDGRSegmentURI(fromChunkedEntry: message), !activeSegmentURIs.contains(segmentURI) {
            activeSegmentURIs.insert(segmentURI)
            let task = Task { [weak self] in
              guard let self else { return }
              await self.streamNDGRSegment(uri: segmentURI)
            }
            segmentTasks[segmentURI] = task
          }
          if let at = parseNDGRNextAt(fromChunkedEntry: message) {
            nextAt = String(at)
          }
          // どれか1メッセージでも届けば「生きてる」と見なし、バックオフをリセット。
          consecutiveFailures = 0
          ndgrReconnectStartedAt = nil
          ndgrLastSuccessAt = Date()
        }
        if !receivedMessage || nextAt == nil {
          throw NSError(
            domain: "NiconicoNativePlayerView",
            code: -3,
            userInfo: [NSLocalizedDescriptionKey: "NDGR VIEW stream closed"]
          )
        }
      } catch {
        if Task.isCancelled || error is CancellationError { return }
        consecutiveFailures += 1
        nextAt = requestAt ?? "now"
        let now = Date()
        if ndgrReconnectStartedAt == nil {
          ndgrReconnectStartedAt = now
        }
        let elapsedSinceSuccess = now.timeIntervalSince(ndgrLastSuccessAt)
        let elapsedSinceReconnect = now.timeIntervalSince(ndgrReconnectStartedAt ?? now)
        // コメントが本当に停止した時だけフル再読み込みへescalate。短い瞬断で連発すると
        // 映像ごと作り直して「ニコ生セッションを準備中」連発＋カクつきになるため控えめに。
        // 一方で「再接続中(1)」のまま無通信で固まるケースは、VIEW stream を短い
        // idle timeout で切り、再接続開始から12秒/3連敗で早めに再読み込みへ上げる。
        if elapsedSinceSuccess > 20 || elapsedSinceReconnect > 12 || consecutiveFailures >= 3 {
          showStatus("ニコ生コメント取得失敗: 再読み込み")
          DispatchQueue.main.async {
            NotificationCenter.default.post(name: .multiViewPlaybackErrored, object: nil)
          }
          return
        }
        let backoff = min(pow(2.0, Double(consecutiveFailures - 1)), 4.0)
        showStatus("ニコ生コメント再接続中 (\(consecutiveFailures))")
        try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
        continue
      }
    }
  }

  // SEGMENT ストリーム: 個々のコメントセグメント。失敗時は VIEW 側が新しい
  // セグメント URI を払い出すので、ここでフル再読み込みを呼ばない。
  private func streamNDGRSegment(uri: String) async {
    defer {
      activeSegmentURIs.remove(uri)
      segmentTasks.removeValue(forKey: uri)
    }
    guard let url = URL(string: uri) else { return }
    do {
      for try await message in protobufMessages(from: url) {
        var handled = false
        if let text = parseNDGRCommentText(fromChunkedMessage: message) {
          emitDanmaku(text)
          handled = true
        }
        if let event = parseNDGRSupportEvent(fromChunkedMessage: message) {
          emitSupportEvent(event)
          handled = true
        } else if let alert = parseNDGRSupportAlert(fromChunkedMessage: message) {
          emitSupportAlert(alert)
          handled = true
        }
        if handled {
          ndgrLastSuccessAt = Date()
        }
      }
    } catch {
      // セグメント単体の失敗は VIEW 側の自動リトライに任せる。
      // ステータス更新も最小限に (ニコ生再接続中はVIEW側が出す)。
    }
  }

  private func protobufMessages(from url: URL, timeoutInterval: TimeInterval = 60) -> AsyncThrowingStream<Data, Error> {
    // Capture headers up front so the streaming Task doesn't retain self. The stream's
    // continuation holds the Task, so capturing self here would form a retain cycle that
    // keeps the player view alive after the stream is removed.
    let headers = niconicoPlaybackHeaders()
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutInterval)
          headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
          let (bytes, response) = try await URLSession.shared.bytes(for: request)
          if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(
              domain: "NiconicoNativePlayerView",
              code: http.statusCode,
              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
            )
          }
          let reader = LengthDelimitedProtobufReader()
          for try await byte in bytes {
            for message in reader.append(byte) {
              continuation.yield(message)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func clearNDGRReconnectStatus() {
    DispatchQueue.main.async {
      if self.statusLabel.text?.hasPrefix("ニコ生コメント再接続中") == true {
        self.statusLabel.isHidden = true
      }
    }
  }

  private func parseNDGRSegmentURI(fromChunkedEntry data: Data) -> String? {
    for field in protobufFields(data) where field.number == 1 {
      for segmentField in protobufFields(field.data) where segmentField.number == 3 {
        return String(data: segmentField.data, encoding: .utf8)
      }
    }
    return nil
  }

  private func parseNDGRNextAt(fromChunkedEntry data: Data) -> Int64? {
    for field in protobufFields(data) where field.number == 4 {
      for nextField in protobufFields(field.data) where nextField.number == 1 {
        return Int64(exactly: nextField.varint)
      }
    }
    return nil
  }

  private func parseNDGRCommentText(fromChunkedMessage data: Data) -> String? {
    for field in protobufFields(data) where field.number == 2 {
      for messageField in protobufFields(field.data) where messageField.number == 1 || messageField.number == 20 {
        for chatField in protobufFields(messageField.data) where chatField.number == 1 {
          return String(data: chatField.data, encoding: .utf8)
        }
      }
    }
    return nil
  }

  private func parseNDGRSupportEvent(fromChunkedMessage data: Data) -> NiconicoSupportEvent? {
    guard let messageFields = nicoliveMessageFields(fromChunkedMessage: data) else { return nil }
    let messageID = parseNDGRMessageID(fromChunkedMessage: data)

    if let giftData = firstFieldData(messageFields, number: 8),
       let event = parseNDGRGift(giftData, id: messageID) {
      return event
    }
    if let nicoadData = firstFieldData(messageFields, number: 9),
       let event = parseNDGRNicoad(nicoadData, id: messageID) {
      return event
    }
    if let notificationData = firstFieldData(messageFields, number: 23),
       let event = parseNDGRSimpleNotificationV2(notificationData, id: messageID) {
      return event
    }
    if let akashicData = firstFieldData(messageFields, number: 24),
       let event = parseNDGRAkashicEvent(akashicData, id: messageID) {
      return event
    }
    if let notificationData = firstFieldData(messageFields, number: 7),
       let event = parseNDGRLegacySimpleNotification(notificationData, id: messageID) {
      return event
    }
    return nil
  }

  private func nicoliveMessageFields(fromChunkedMessage data: Data) -> [ProtobufField]? {
    for field in protobufFields(data) where field.number == 2 {
      return protobufFields(field.data)
    }
    return nil
  }

  private func parseNDGRMessageID(fromChunkedMessage data: Data) -> String? {
    guard let metaData = firstFieldData(protobufFields(data), number: 1) else { return nil }
    let metaFields = protobufFields(metaData)
    if let id = firstNonEmpty([stringField(metaFields, 1), stringField(metaFields, 2), stringField(metaFields, 3)]) {
      return id
    }
    return protobufStrings(in: metaData)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { text in
        text.count >= 8
          && text.count <= 80
          && text.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil
      }
  }

  private func parseNDGRGift(_ data: Data, id: String?) -> NiconicoSupportEvent? {
    let fields = protobufFields(data)
    let itemID = stringField(fields, 1)
    let sender = stringField(fields, 3)
    let points = intField(fields, 4)
    let message = stringField(fields, 5)
    let itemName = firstNonEmpty([
      stringField(fields, 6),
      itemID?.contains("/") == false ? itemID : nil,
      "ギフト"
    ]) ?? "ギフト"
    let rank = intField(fields, 7)
    let giftBar = firstFieldData(fields, number: 8).flatMap(parseNDGRGiftBarUpdate)
    let assetURL = firstGiftAssetURL(in: data) ?? NiconicoGiftEffectCache.shared.thumbnailURL(forItemID: itemID)
    let style = classifyGiftEffect(itemID: itemID, itemName: itemName, message: message, points: points)
    NiconicoGiftEffectCache.shared.prewarmGiftItem(itemID: itemID)

    let giver = firstNonEmpty([sender, "匿名"])
    let title = compactSupportText("\(giver ?? "匿名") が \(itemName) を贈りました", limit: 44)
    let subtitle = supportSubtitle([
      points.map(formatPoints),
      rank.map { "貢献\($0)位" },
      compactOptionalSupportText(message, limit: 44),
      giftBar?.summary
    ])
    return NiconicoSupportEvent(
      id: id,
      kind: .gift,
      title: title,
      subtitle: subtitle,
      giftBar: giftBar,
      effectStyle: style,
      assetURL: assetURL
    )
  }

  private func parseNDGRGiftBarUpdate(_ data: Data) -> NiconicoGiftBarUpdate? {
    let fields = protobufFields(data)
    let update = NiconicoGiftBarUpdate(
      currentLevel: intField(fields, 1),
      nextLevelRewardCount: intField(fields, 2),
      remainingPointsForNextLevel: intField(fields, 3),
      requiredPointsForNextLevel: intField(fields, 4)
    )
    if update.currentLevel == nil,
       update.nextLevelRewardCount == nil,
       update.remainingPointsForNextLevel == nil,
       update.requiredPointsForNextLevel == nil {
      return nil
    }
    return update
  }

  private func parseNDGRNicoad(_ data: Data, id: String?) -> NiconicoSupportEvent? {
    let fields = protobufFields(data)
    if let v1Data = firstFieldData(fields, number: 2) {
      let v1Fields = protobufFields(v1Data)
      let totalPoint = intField(v1Fields, 1)
      let message = stringField(v1Fields, 2)
      let title = compactSupportText(firstNonEmpty([message, "ニコニ広告されました"]) ?? "ニコニ広告されました", limit: 50)
      let subtitle = supportSubtitle([totalPoint.map { "合計\(formatPoints($0))" }])
      return NiconicoSupportEvent(id: id, kind: .nicoad, title: title, subtitle: subtitle, giftBar: nil, effectStyle: .nicoad, assetURL: nil)
    }
    if let v0Data = firstFieldData(fields, number: 1) {
      let v0Fields = protobufFields(v0Data)
      let totalPoint = intField(v0Fields, 3)
      let latestFields = firstFieldData(v0Fields, number: 1).map(protobufFields) ?? []
      let advertiser = stringField(latestFields, 1)
      let latestPoint = intField(latestFields, 2)
      let message = stringField(latestFields, 3)
      let titleText = firstNonEmpty([
        message,
        advertiser.map { "\($0) がニコニ広告しました" },
        "ニコニ広告されました"
      ]) ?? "ニコニ広告されました"
      let subtitle = supportSubtitle([
        latestPoint.map { "今回\(formatPoints($0))" },
        totalPoint.map { "合計\(formatPoints($0))" }
      ])
      return NiconicoSupportEvent(
        id: id,
        kind: .nicoad,
        title: compactSupportText(titleText, limit: 50),
        subtitle: subtitle,
        giftBar: nil,
        effectStyle: .nicoad,
        assetURL: nil
      )
    }
    return nil
  }

  private func parseNDGRSimpleNotificationV2(_ data: Data, id: String?) -> NiconicoSupportEvent? {
    let fields = protobufFields(data)
    let type = intField(fields, 1)
    guard let message = stringField(fields, 2),
          shouldShowSupportNotification(type: type, message: message) else { return nil }
    let title = compactSupportText(message, limit: 52)
    let subtitle = supportNotificationLabel(type).map { "ニコ生\($0)" }
    return NiconicoSupportEvent(id: id, kind: .notification, title: title, subtitle: subtitle, giftBar: nil, effectStyle: .levelUp, assetURL: nil)
  }

  private func parseNDGRLegacySimpleNotification(_ data: Data, id: String?) -> NiconicoSupportEvent? {
    let strings = protobufStrings(in: data)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard let message = strings.first(where: containsSupportMarker) else { return nil }
    return NiconicoSupportEvent(
      id: id,
      kind: .notification,
      title: compactSupportText(message, limit: 52),
      subtitle: "ニコ生通知",
      giftBar: nil,
      effectStyle: .levelUp,
      assetURL: nil
    )
  }

  private func parseNDGRAkashicEvent(_ data: Data, id: String?) -> NiconicoSupportEvent? {
    let fields = protobufFields(data)
    let type = stringField(fields, 1)
    let playID = stringField(fields, 2)
    let strings = protobufStrings(in: data)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let probe = ([type, playID].compactMap { $0 } + strings).joined(separator: " ")
    let lowerType = (type ?? "").lowercased()
    let isSupportEvent = containsSupportMarker(probe)
      || lowerType.contains("gift")
      || lowerType.contains("nicoad")
      || lowerType.contains("support")
      || lowerType.contains("koken")
    guard isSupportEvent else { return nil }

    let userFacing = strings.first { text in
      containsSupportMarker(text) && text != type && text != playID
    }
    let titleText: String
    if let userFacing {
      titleText = userFacing
    } else if lowerType.contains("gift") {
      titleText = "ギフト演出が始まりました"
    } else if lowerType.contains("nicoad") {
      titleText = "ニコニ広告演出が始まりました"
    } else {
      titleText = "ニコ生演出が始まりました"
    }
    let subtitle = type.map { "Akashic: \($0)" }
    return NiconicoSupportEvent(
      id: id,
      kind: .akashic,
      title: compactSupportText(titleText, limit: 52),
      subtitle: compactOptionalSupportText(subtitle, limit: 48),
      giftBar: nil,
      effectStyle: .akashic,
      assetURL: firstGiftAssetURL(in: data)
    )
  }

  private func classifyGiftEffect(itemID: String?, itemName: String, message: String?, points: Int?) -> NativeGiftEffectStyle {
    let source = [itemID, itemName, message]
      .compactMap { $0?.lowercased() }
      .joined(separator: " ")
    if containsAny(source, ["花火", "firework", "爆", "弾幕"]) {
      return .firework
    }
    if containsAny(source, ["ハート", "heart", "love", "愛"]) {
      return .heart
    }
    if containsAny(source, ["星", "スター", "star"]) {
      return .star
    }
    if containsAny(source, ["花", "桜", "sakura", "flower", "rose", "leaf"]) {
      return .flower
    }
    if containsAny(source, ["肉", "寿司", "ラーメン", "弁当", "ケーキ", "cake", "food", "drink"]) {
      return .food
    }
    if containsAny(source, ["ロケット", "rocket", "ミサイル", "飛行機"]) {
      return .rocket
    }
    if let points, points >= 1_000 {
      return .premiumGift
    }
    return .gift
  }

  private func firstGiftAssetURL(in data: Data) -> URL? {
    protobufStrings(in: data)
      .lazy
      .compactMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
      .first { url in
        guard url.scheme == "https",
              let host = url.host?.lowercased() else { return false }
        let allowedHost = host.hasSuffix("nicovideo.jp") || host.hasSuffix("nimg.jp") || host.hasSuffix("nico.ms")
        let lowerPath = url.path.lowercased()
        let isImageLike = lowerPath.hasSuffix(".png")
          || lowerPath.hasSuffix(".jpg")
          || lowerPath.hasSuffix(".jpeg")
          || lowerPath.hasSuffix(".gif")
          || lowerPath.hasSuffix(".webp")
        return allowedHost && isImageLike
      }
  }

  private func containsAny(_ text: String, _ needles: [String]) -> Bool {
    needles.contains { text.contains($0.lowercased()) }
  }

  private func firstFieldData(_ fields: [ProtobufField], number: Int) -> Data? {
    fields.first(where: { $0.number == number })?.data
  }

  private func stringField(_ fields: [ProtobufField], _ number: Int) -> String? {
    fields
      .filter { $0.number == number }
      .compactMap { String(data: $0.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
  }

  private func intField(_ fields: [ProtobufField], _ number: Int) -> Int? {
    fields
      .filter { $0.number == number }
      .compactMap { Int(exactly: $0.varint) }
      .first
  }

  private func firstNonEmpty(_ values: [String?]) -> String? {
    values
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
  }

  private func supportSubtitle(_ parts: [String?]) -> String? {
    let text = parts
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " / ")
    return text.isEmpty ? nil : compactSupportText(text, limit: 74)
  }

  private func compactOptionalSupportText(_ text: String?, limit: Int) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return compactSupportText(text, limit: limit)
  }

  private func compactSupportText(_ text: String, limit: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit, limit > 3 else { return trimmed }
    return String(trimmed.prefix(limit - 3)) + "..."
  }

  private func formatPoints(_ points: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return "\((formatter.string(from: NSNumber(value: points)) ?? String(points)))pt"
  }

  private func supportNotificationLabel(_ type: Int?) -> String? {
    switch type {
    case 7:
      return "サポーター"
    case 8:
      return "レベルアップ"
    default:
      return nil
    }
  }

  private func shouldShowSupportNotification(type: Int?, message: String) -> Bool {
    if type == 7 || type == 8 { return true }
    return containsSupportMarker(message)
  }

  private func containsSupportMarker(_ text: String) -> Bool {
    let markers = [
      "ギフト",
      "ニコニ広告",
      "広告しました",
      "貢献",
      "サポーター",
      "レベルアップ",
      "gift",
      "nicoad",
      "support",
      "koken"
    ]
    let lowercased = text.lowercased()
    return markers.contains { lowercased.contains($0.lowercased()) }
  }

  private func parseNDGRSupportAlert(fromChunkedMessage data: Data) -> String? {
    let strings = protobufStrings(in: data)
    let useful = strings
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { text in
        text.count >= 2
          && text.count <= 80
          && !text.contains("https://")
          && !text.contains("http://")
      }
    // 公式は「【ギフト貢献N位】Xさんがギフト「Y」を贈りました」「Xさんがニコニ広告しました」など、
     // 中身が可変な合成文を出す。ギフトの種類名で挟まれて部分文字列も切れるので、特徴的なトークンを広めに拾う。
    let officialMarkers = [
      "ギフトを贈りました",
      "ギフトが贈られました",
      "ギフトしました",
      "ギフト「",
      "ギフト貢献",
      "を贈りました",
      "ニコニ広告しました",
      "広告しました",
      "pt貢献",
      "ptを貢献",
      "ptを献",
      "貢献しました"
    ]
    let hasOfficialSentence = officialMarkers.contains { marker in useful.contains { $0.contains(marker) } }
    guard hasOfficialSentence else {
      return nil
    }
    if let sentence = useful.first(where: { text in officialMarkers.contains { text.contains($0) } }) {
      return "ニコ生: \(sentence)"
    }
    return "ニコ生: ギフト/広告が送られました"
  }

  private func protobufStrings(in data: Data, depth: Int = 0) -> [String] {
    guard depth < 5 else { return [] }
    var result: [String] = []
    for field in protobufFields(data) {
      if field.number > 0, let text = String(data: field.data, encoding: .utf8), Self.isUsefulProtoString(text) {
        result.append(text)
      }
      result.append(contentsOf: protobufStrings(in: field.data, depth: depth + 1))
    }
    return result
  }

  private static func isUsefulProtoString(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2, trimmed.count <= 120 else { return false }
    return trimmed.unicodeScalars.allSatisfy { scalar in
      scalar.value == 0x09 || scalar.value == 0x0a || scalar.value == 0x0d || scalar.value >= 0x20
    }
  }

  private func parseWatchData(from html: String) throws -> (webSocketURL: URL, frontendId: String?, endDate: Date?) {
    guard let encoded = firstMatch(in: html, pattern: #"<script[^>]+id=["']initial-state["'][^>]+data-props=["']([^"']+)["']"#)
      ?? firstMatch(in: html, pattern: #"data-props=["']([^"']+)["'][^>]+id=["']initial-state["']"#)
      ?? firstMatch(in: html, pattern: #"<script[^>]+id=["']embedded-data["'][^>]+data-props=["']([^"']+)["']"#)
      ?? firstMatch(in: html, pattern: #"data-props=["']([^"']+)["'][^>]+id=["']embedded-data["']"#) else {
      throw NSError(domain: "NiconicoNativePlayerView", code: 1)
    }
    let decoded = decodeHTMLEntities(encoded)
    guard let data = decoded.data(using: .utf8),
          let props = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw NSError(domain: "NiconicoNativePlayerView", code: 2)
    }
    if let pageContents = props["pageContents"] as? [String: Any],
       let watchInformation = pageContents["watchInformation"] as? [String: Any],
       let playerParams = watchInformation["playerParams"] as? [String: Any],
       let wsEndPoint = playerParams["wsEndPoint"] as? [String: Any],
       let wsString = wsEndPoint["url"] as? String,
       !wsString.isEmpty,
       let url = URL(string: wsString) {
      let constants = props["constants"] as? [String: Any]
      let requestInfo = constants?["requestInfo"] as? [String: Any]
      let frontendId = (requestInfo?["frontendId"] as? String)
        ?? (requestInfo?["frontendId"] as? Int).map(String.init)
      return (url, frontendId, Self.findProgramEndDate(in: props))
    }
    guard let site = props["site"] as? [String: Any] else {
      throw NSError(domain: "NiconicoNativePlayerView", code: 4)
    }
    let relive = site["relive"] as? [String: Any]
    let wsString = relive?["webSocketUrl"] as? String
      ?? site["webSocketUrl"] as? String
      ?? site["websocketUrl"] as? String
    guard let wsString, let url = URL(string: wsString) else {
      throw NSError(domain: "NiconicoNativePlayerView", code: 3)
    }
    let frontendId = (site["frontendId"] as? String)
      ?? (site["frontendId"] as? Int).map(String.init)
      ?? (site["frontendID"] as? String)
    return (url, frontendId, Self.findProgramEndDate(in: props))
  }

  private static func findProgramEndDate(in value: Any) -> Date? {
    var candidates: [Date] = []
    collectProgramEndDates(in: value, currentKey: "", into: &candidates)
    let now = Date()
    return candidates
      .filter { $0.timeIntervalSince(now) > -60 }
      .sorted()
      .first
  }

  private static func collectProgramEndDates(in value: Any, currentKey: String, into candidates: inout [Date]) {
    if let dict = value as? [String: Any] {
      for (key, nested) in dict {
        collectProgramEndDates(in: nested, currentKey: key, into: &candidates)
      }
      return
    }
    if let array = value as? [Any] {
      array.forEach { collectProgramEndDates(in: $0, currentKey: currentKey, into: &candidates) }
      return
    }
    let key = currentKey.lowercased()
    guard key.contains("end") || key.contains("expire") || key.contains("close") else { return }
    if let number = value as? NSNumber {
      let raw = number.doubleValue
      let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
      let date = Date(timeIntervalSince1970: seconds)
      if date.timeIntervalSince1970 > 1_600_000_000 {
        candidates.append(date)
      }
      return
    }
    if let text = value as? String {
      if let raw = Double(text) {
        let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
        let date = Date(timeIntervalSince1970: seconds)
        if date.timeIntervalSince1970 > 1_600_000_000 {
          candidates.append(date)
        }
        return
      }
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: text) {
        candidates.append(date)
        return
      }
      formatter.formatOptions = [.withInternetDateTime]
      if let date = formatter.date(from: text) {
        candidates.append(date)
      }
    }
  }

  private func firstMatch(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
          let valueRange = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[valueRange])
  }

  private func decodeHTMLEntities(_ text: String) -> String {
    var output = text
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#34;", with: "\"")
      .replacingOccurrences(of: "&#x22;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&#x27;", with: "'")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&amp;", with: "&")
    let pattern = #"&#x([0-9a-fA-F]+);"#
    if let regex = try? NSRegularExpression(pattern: pattern) {
      for match in regex.matches(in: output, range: NSRange(output.startIndex..<output.endIndex, in: output)).reversed() {
        guard let range = Range(match.range(at: 1), in: output),
              let code = UInt32(output[range], radix: 16),
              let scalar = UnicodeScalar(code),
              let fullRange = Range(match.range(at: 0), in: output) else { continue }
        output.replaceSubrange(fullRange, with: String(scalar))
      }
    }
    return output
  }

  private struct ProtobufField {
    let number: Int
    let data: Data
    let varint: UInt64
  }

  private func protobufFields(_ data: Data) -> [ProtobufField] {
    var fields: [ProtobufField] = []
    var offset = 0
    while offset < data.count, let key = readVarint(data, offset: &offset) {
      let number = Int(key >> 3)
      let wireType = Int(key & 0x07)
      switch wireType {
      case 0:
        guard let value = readVarint(data, offset: &offset) else { return fields }
        fields.append(ProtobufField(number: number, data: Data(), varint: value))
      case 1:
        guard offset + 8 <= data.count else { return fields }
        offset += 8
      case 2:
        guard let length = readVarint(data, offset: &offset) else { return fields }
        guard length <= UInt64(Int.max) else { return fields }
        let end = offset + Int(length)
        guard end <= data.count else { return fields }
        fields.append(ProtobufField(number: number, data: data.subdata(in: offset..<end), varint: 0))
        offset = end
      case 5:
        guard offset + 4 <= data.count else { return fields }
        offset += 4
      default:
        return fields
      }
    }
    return fields
  }

  private func readVarint(_ data: Data, offset: inout Int) -> UInt64? {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    while offset < data.count, shift < 64 {
      let byte = data[offset]
      offset += 1
      result |= UInt64(byte & 0x7f) << shift
      if byte & 0x80 == 0 {
        return result
      }
      shift += 7
    }
    return nil
  }

  private final class LengthDelimitedProtobufReader {
    private var buffer: [UInt8] = []

    func append(_ byte: UInt8) -> [Data] {
      buffer.append(byte)
      var messages: [Data] = []
      while let message = nextMessage() {
        messages.append(message)
      }
      return messages
    }

    private func nextMessage() -> Data? {
      var offset = 0
      var length = 0
      var shift = 0
      while offset < buffer.count {
        let byte = buffer[offset]
        length |= Int(byte & 0x7f) << shift
        offset += 1
        if byte & 0x80 == 0 {
          guard buffer.count >= offset + length else { return nil }
          let payload = Data(buffer[offset..<(offset + length)])
          buffer.removeFirst(offset + length)
          return payload
        }
        shift += 7
        if shift > 28 { return nil }
      }
      return nil
    }
  }

  // 共通の lane-occupancy レンダラへ統一(Codex#3)。旧独自実装は round-robin(laneCursor%maxLines)で
  // 重なりやすく、CALayer shadow で off-screen render も重かった。NativeDanmakuRenderer.emit は
  // 空きレーン選択＋属性文字列影でそれらを解決済み(maxLength/フォント/不透明度も内部で処理)。
  private func emitDanmaku(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    DispatchQueue.main.async {
      self.laneCursor = NativeDanmakuRenderer.emit(
        tokens: NativeDanmakuRenderer.textTokens(trimmed),
        filterText: trimmed,
        in: self.danmakuView,
        laneCursor: self.laneCursor,
        settings: self.settings
      )
    }
  }

  func emitOwnComment(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    DispatchQueue.main.async {
      self.laneCursor = NativeDanmakuRenderer.emit(
        tokens: NativeDanmakuRenderer.textTokens(trimmed),
        filterText: trimmed,
        in: self.danmakuView,
        laneCursor: self.laneCursor,
        settings: self.settings,
        highlighted: true
      )
    }
  }

  private func emitSupportEvent(_ event: NiconicoSupportEvent) {
    DispatchQueue.main.async {
      // 種別ごとの表示オン/オフ(設定)。OFFの種別はここで弾く。
      switch event.kind {
      case .gift: guard self.settings.niconicoShowGift else { return }
      case .nicoad: guard self.settings.niconicoShowNicoad else { return }
      case .notification, .akashic: guard self.settings.niconicoShowNotification else { return }
      }
      if let id = event.id {
        if self.seenSupportEventIDs.contains(id) { return }
        if self.seenSupportEventIDs.count > 500 {
          self.seenSupportEventIDs.removeAll(keepingCapacity: true)
        }
        self.seenSupportEventIDs.insert(id)
      }

      let dedupeText = "\(event.kind):\(event.title):\(event.subtitle ?? "")"
      let now = Date()
      if let lastSupportAlert = self.lastSupportAlert,
         lastSupportAlert.text == dedupeText,
         now.timeIntervalSince(lastSupportAlert.at) < 8 {
        return
      }
      self.lastSupportAlert = (dedupeText, now)
      NiconicoGiftEffectCache.shared.prewarmAsset(event.assetURL)
      NativeGiftSoundMixer.shared.play(style: event.effectStyle, enabled: self.settings.giftSoundEnabled, volume: self.playbackVolume)
      self.showSupportEvent(event)
    }
  }

  private func showSupportEvent(_ event: NiconicoSupportEvent) {
    let present: (UIImage?) -> Void = { [weak self] image in
      guard let self else { return }
      NativeEventOverlay.showSupport(
        title: event.title,
        subtitle: event.subtitle,
        symbolName: event.symbolName,
        progress: event.giftBar?.progress,
        effectStyle: event.effectStyle,
        assetImage: image,
        in: self.danmakuView,
        tint: StreamPlatform.niconico.tint
      )
    }

    if let cached = NiconicoGiftEffectCache.shared.cachedImage(for: event.assetURL) {
      present(cached)
      return
    }

    guard event.assetURL != nil else {
      present(nil)
      return
    }

    let gate = NativeOnceGate()
    NiconicoGiftEffectCache.shared.loadImage(for: event.assetURL) { image in
      gate.run {
        present(image)
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
      gate.run {
        present(nil)
      }
    }
  }

  private func emitSupportAlert(_ text: String) {
    let now = Date()
    if let lastSupportAlert, lastSupportAlert.text == text, now.timeIntervalSince(lastSupportAlert.at) < 10 {
      return
    }
    lastSupportAlert = (text, now)
    NativeGiftSoundMixer.shared.play(style: .gift, enabled: settings.giftSoundEnabled, volume: playbackVolume)
    NativeEventOverlay.showSupport(
      title: compactSupportText(text, limit: 52),
      subtitle: nil,
      symbolName: NativeGiftEffectStyle.gift.heroSymbol,
      progress: nil,
      effectStyle: .gift,
      assetImage: nil,
      in: danmakuView,
      tint: StreamPlatform.niconico.tint
    )
  }

  private func showStatus(_ text: String) {
    DispatchQueue.main.async {
      self.statusLabel.text = text
      self.statusLabel.isHidden = false
    }
  }

  static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
}

// Kick=Amazon IVS の標準HLSは実セグメント2秒なのに TARGETDURATION=6 で、AVPlayer は
// 3×TARGETDURATION≒18秒ライブ端から後ろに居座る(=体感10秒超の遅延)。コンテンツ自体は実時間に
// 来ている(実測: 端の遅延 ≒0秒)。そこでプレイリストを横取りし、メディアプレイリストの
// TARGETDURATION を 2 へ書き換えて AVPlayer を端の約6秒手前まで寄らせる(IVS低遅延モード相当)。
// マスターは子(メディア)プレイリストURLを自スキームへ向けて横取り対象にするだけ。セグメント(.ts)は
// httpsのまま直接取得させる(無駄な横取りを避ける)。取得失敗時は item が .failed → installFallback。
final class KickLowLatencyLoader: NSObject, AVAssetResourceLoaderDelegate {
  static let scheme = "mvkickll"
  private let headers: [String: String]
  private let session = URLSession(configuration: .ephemeral)

  init(headers: [String: String]) {
    self.headers = headers
    super.init()
  }

  private func realURL(from url: URL) -> URL? {
    var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    comps?.scheme = "https"
    return comps?.url
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                      shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
    guard let requestURL = loadingRequest.request.url,
          requestURL.scheme == Self.scheme,
          let real = realURL(from: requestURL) else { return false }
    var req = URLRequest(url: real)
    headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
    session.dataTask(with: req) { data, response, error in
      if let error {
        loadingRequest.finishLoading(with: error)
        return
      }
      // このローダーへの要求は必ずプレイリスト(マスター/メディア)。セグメント(.ts)はhttps直取得。
      // 非2xx(トークン失効の403等)やプレイリスト以外(HTMLエラー本文)を有効データとして
      // AVPlayerへ渡すと不正データで詰まる(=「開けません」)ため、ここで明示的に失敗させ、
      // 上位の再取得リトライ(handleNativeFailure)へ繋ぐ。Codex指摘①。
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200..<300).contains(status), let data,
            let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
        loadingRequest.finishLoading(with: NSError(
          domain: "KickLL", code: status == 0 ? -1 : status,
          userInfo: [NSLocalizedDescriptionKey: "Kickプレイリスト取得失敗(HTTP \(status))"]))
        return
      }
      let outData = Data(Self.rewritePlaylist(text).utf8)
      loadingRequest.contentInformationRequest?.contentType = "application/vnd.apple.mpegurl"
      loadingRequest.contentInformationRequest?.contentLength = Int64(outData.count)
      loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
      loadingRequest.dataRequest?.respond(with: outData)
      loadingRequest.finishLoading()
    }.resume()
    return true
  }

  private static func rewritePlaylist(_ text: String) -> String {
    if text.contains("#EXT-X-STREAM-INF") {
      // マスター: 子(メディア)プレイリストの https:// を自スキームへ向けて横取り対象にする。
      // (EXT-X-START 注入は AVPlayer が尊重せず無効だったため撤去。TARGETDURATION 書換のみ有効。)
      return text.replacingOccurrences(of: "https://", with: "\(scheme)://")
    }
    // メディア: TARGETDURATION を 2 に下げてライブ端へ寄せる。セグメントURL(https)は触らない。
    return text.replacingOccurrences(
      of: "#EXT-X-TARGETDURATION:[0-9]+",
      with: "#EXT-X-TARGETDURATION:2",
      options: .regularExpression)
  }
}

final class KickNativePlayerView: UIView, PlaybackResumable, PlaybackStoppable, AudioControllable, CommentPostable, CommentEchoDisplay {
  private let stream: StreamItem
  private let settings: AppSettings
  private let player = AVPlayer()
  private let playerLayer = AVPlayerLayer()
  private let danmakuView = UIView()
  private let statusLabel = UILabel()
  private var playbackVolume: Float
  private var channelTask: URLSessionDataTask?
  private var socketTask: URLSessionWebSocketTask?
  private var itemStatusObservation: NSKeyValueObservation?
  private var itemFailedObserver: NSObjectProtocol?
  private var fallbackWebView: PlayerWebView?
  private var chatroomID: String?
  private var kickChannelID: String?
  private var liveCatchUpTimer: Timer?
  private var lowLatencyLoader: KickLowLatencyLoader?
  // 直近のplayback_url(素HLS再試行用)、再生世代(古いitemのKVO/通知を無視)、
  // ネイティブ再取得リトライ(トークン失効時に新URL取得。上限超過でのみweb UIへ)。Codex指摘②③④。
  private var currentHLSURL: URL?
  private var playbackGeneration = 0
  private let nativeRetry = NativeRetryLimiter(maxAttempts: 2)
  // 連続ストールでアグレッシブな低遅延(LLローダー+ライブ端追従)を一時停止し安定優先へ切替。
  // 一定時間ストール無しで自動復帰(次回再接続からLL有効)。Codex#1 part2。
  private var stallCount = 0
  private var stableMode = false
  private var stallCountResetWork: DispatchWorkItem?
  private var stableModeResetWork: DispatchWorkItem?
  private lazy var stallWatchdog = StallWatchdog(player: player) { [weak self] in
    self?.recoverFromStall()
  }
  private var isLoading = false
  private var isStopped = false
  private var laneCursor = 0

  init(stream: StreamItem, settings: AppSettings) {
    self.stream = stream
    self.settings = settings
    self.playbackVolume = StreamVolumeStore.volume(for: stream)
    super.init(frame: .zero)
    backgroundColor = .black

    player.automaticallyWaitsToMinimizeStalling = false
    player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    playerLayer.player = player
    playerLayer.videoGravity = .resizeAspect
    layer.addSublayer(playerLayer)

    danmakuView.isUserInteractionEnabled = false
    danmakuView.clipsToBounds = true
    addSubview(danmakuView)

    statusLabel.text = "Kickをネイティブ再生で読み込み中"
    statusLabel.textColor = .white.withAlphaComponent(0.72)
    statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 0
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(statusLabel)
    NSLayoutConstraint.activate([
      statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
    ])

    PlaybackCoordinator.shared.register(self)
    loadNativeStream()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    stopPlayback()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    playerLayer.frame = bounds
    danmakuView.frame = bounds
  }

  func resumePlayback() {
    guard !isStopped else { return }
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default, options: [])
    try? session.setActive(true)
    if let fallbackWebView {
      fallbackWebView.resumePlayback()
      return
    }
    if player.currentItem == nil {
      loadNativeStream()
      return
    }
    player.isMuted = !settings.playAudio
    player.volume = settings.playAudio ? playbackVolume : 0
    player.play()
  }

  func pausePlayback() {
    player.pause()
    fallbackWebView?.pausePlayback()
  }

  func postComment(_ text: String, completion: @escaping (Result<Void, Error>) -> Void) {
    guard KickAuthManager.shared.isSignedIn else {
      completion(.failure(NSError(domain: "Kick", code: 401, userInfo: [NSLocalizedDescriptionKey: "設定でKickにログインしてください"])))
      return
    }
    KickAuthManager.shared.sendChat(channel: stream.channel, content: text, completion: completion)
  }

  func stopPlayback() {
    isStopped = true
    stallWatchdog.stop()
    stallCountResetWork?.cancel()
    stallCountResetWork = nil
    stableModeResetWork?.cancel()
    stableModeResetWork = nil
    liveCatchUpTimer?.invalidate()
    liveCatchUpTimer = nil
    lowLatencyLoader = nil
    channelTask?.cancel()
    channelTask = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    socketTask?.cancel(with: .goingAway, reason: nil)
    socketTask = nil
    chatroomID = nil
    kickChannelID = nil
    fallbackWebView?.stopPlayback()
    fallbackWebView?.removeFromSuperview()
    fallbackWebView = nil
    itemStatusObservation = nil
    if let itemFailedObserver {
      NotificationCenter.default.removeObserver(itemFailedObserver)
      self.itemFailedObserver = nil
    }
  }

  func setPlaybackVolume(_ volume: Float) {
    playbackVolume = min(1, max(0, volume))
    player.volume = settings.playAudio ? playbackVolume : 0
    fallbackWebView?.setPlaybackVolume(playbackVolume)
  }

  private func loadNativeStream() {
    guard !isStopped, !isLoading, fallbackWebView == nil else { return }
    let channel = stream.channel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let escaped = channel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          let url = URL(string: "https://kick.com/api/v2/channels/\(escaped)") else {
      installFallback("Kickチャンネル名が不正です")
      return
    }
    isLoading = true
    showStatus("Kickをネイティブ再生で読み込み中")
    syncKickWebCookies { [weak self] in
      self?.fetchKickChannel(url: url, channel: channel)
    }
  }

  private func fetchKickChannel(url: URL, channel: String) {
    guard !isStopped else { return }
    var request = URLRequest(url: url)
    kickHeaders().forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    channelTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.channelTask = nil
      self.isLoading = false
      if let error {
        self.installFallback("Kick HLS取得失敗: \(error.localizedDescription)")
        return
      }
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        self.installFallback("Kick HLS取得失敗: HTTP \(http.statusCode)")
        return
      }
      guard let data else {
        self.installFallback("Kick HLS URLを取得できません")
        return
      }
      let channelInfo = Self.extractChannelInfo(from: data)
      self.kickChannelID = channelInfo.channelID
      if let chatroomID = channelInfo.chatroomID {
        self.connectKickComments(chatroomID: chatroomID)
      } else {
        self.fetchKickChatroom(channel: channel)
      }
      guard let hlsURL = channelInfo.hlsURL else {
        self.installFallback("Kick HLS URLを取得できません")
        return
      }
      self.play(hlsURL: hlsURL)
    }
    channelTask?.resume()
  }

  private func fetchKickChatroom(channel: String) {
    guard (settings.showChat || settings.autoFollowRaids), !isStopped else { return }
    guard let escaped = channel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          let url = URL(string: "https://kick.com/api/v2/channels/\(escaped)/chatroom") else { return }
    var request = URLRequest(url: url)
    kickHeaders().forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
      guard let self, !self.isStopped else { return }
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        if http.statusCode == 401 || http.statusCode == 403 {
          self.showStatus("Kick R18コメントは18歳以上確認済みログインが必要です")
        }
        return
      }
      guard let data, let chatroomID = Self.extractChatroomID(from: data) else { return }
      self.connectKickComments(chatroomID: chatroomID)
    }.resume()
  }

  // lowLatency=true は TARGETDURATION 書換ローダー経由。これで AVPlayer が稀に開けない
  // (cannot open 等)ことがあるため、失敗時は lowLatency=false の素HLSでネイティブ再試行し、
  // それでもダメな時だけ web UI フォールバックへ。これで「cannot open→Kick独自UI」を防ぐ。
  private func play(hlsURL: URL, lowLatency: Bool = true) {
    DispatchQueue.main.async {
      guard !self.isStopped else { return }
      self.statusLabel.isHidden = true
      self.currentHLSURL = hlsURL
      self.playbackGeneration += 1
      let generation = self.playbackGeneration
      // 安定モード中は低遅延ローダーを使わず素HLS(ライブ端から自然に離れ=ストール抑制)。Codex#1 part2。
      let useLowLatency = lowLatency && !self.stableMode
      let headers = self.kickPlaybackHeaders()
      let assetURL: URL
      if useLowLatency, var llComponents = URLComponents(url: hlsURL, resolvingAgainstBaseURL: false) {
        llComponents.scheme = KickLowLatencyLoader.scheme
        assetURL = llComponents.url ?? hlsURL
      } else {
        assetURL = hlsURL
      }
      let asset = AVURLAsset(url: assetURL, options: [
        "AVURLAssetHTTPHeaderFieldsKey": headers,
        // Live HLS never needs a precise duration; skip that analysis to trim startup.
        AVURLAssetPreferPreciseDurationAndTimingKey: false
      ])
      if assetURL.scheme == KickLowLatencyLoader.scheme {
        let loader = KickLowLatencyLoader(headers: headers)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "app.multiview.kick.ll"))
        self.lowLatencyLoader = loader
      } else {
        self.lowLatencyLoader = nil
      }
      let item = AVPlayerItem(asset: asset)
      item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
      item.preferredPeakBitRate = NetworkQuality.shared.effectivePeakBitRate(settings: self.settings)
      // Kick は低遅延HLS(LL-HLS)。ライブ端からのオフセットを 4→2 秒へ詰めて公式アプリとの
      // 遅延差を縮める(automaticallyWaitsToMinimizeStalling=false と整合)。回線が細いと
      // リバッファ寄りになるトレードオフ。通常HLSではこのプロパティは no-op。要実機A/B。
      item.configuredTimeOffsetFromLive = CMTime(seconds: 1.5, preferredTimescale: 600)
      item.automaticallyPreservesTimeOffsetFromLive = true
      self.itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
        if item.status == .failed {
          self?.handleNativeFailure(
            item.error?.localizedDescription ?? "Kickネイティブ再生に失敗しました",
            wasLowLatency: useLowLatency, generation: generation)
        } else if item.status == .readyToPlay {
          DispatchQueue.main.async {
            guard let self, generation == self.playbackGeneration else { return }
            self.nativeRetry.reset()   // 再生成功で再取得カウンタをリセット(長時間再生でも枯渇しない)
            self.scheduleStableModeReset()
            self.resumePlayback()
            self.startLiveCatchUp()
            self.stallWatchdog.start()
          }
        }
      }
      if let itemFailedObserver = self.itemFailedObserver {
        NotificationCenter.default.removeObserver(itemFailedObserver)
      }
      self.itemFailedObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemFailedToPlayToEndTime,
        object: item,
        queue: .main
      ) { [weak self] notification in
        // しばらく再生後に停止 → web UIへ即落とさず、素HLS再試行→playback_url再取得を試す。Codex指摘②。
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
        self?.handleNativeFailure(
          error?.localizedDescription ?? "Kickネイティブ再生が停止しました",
          wasLowLatency: useLowLatency, generation: generation)
      }
      self.player.replaceCurrentItem(with: item)
      self.player.isMuted = !self.settings.playAudio
      self.player.volume = self.settings.playAudio ? self.playbackVolume : 0
      self.player.play()
    }
  }

  // リバースエンジニアリング結果: Kick=Amazon IVS の標準HLS(v3)で、実セグメントは2秒なのに
  // TARGETDURATION=6。AVPlayer は TARGETDURATION 基準でライブ端から約3倍(≒18秒)後ろに居座る
  // ため、2秒セグメントが端近くにあっても遅延が大きい(体感10秒超)。LL-HLSタグは無いので
  // configuredTimeOffsetFromLive は効かない。対策: 再生中に周期的にシーク可能範囲の端付近
  // (端から3秒手前=多少のバッファ)へ寄せて遅延を詰める。Kickのみ・要実機A/B・戻すのは容易。
  private func startLiveCatchUp() {
    guard !stableMode else { return }   // 安定モードではライブ端追従せずバッファ温存(ストール抑制)
    liveCatchUpTimer?.invalidate()
    liveCatchUpTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
      self?.catchUpToLiveEdge()
    }
    catchUpToLiveEdge()
  }

  private func catchUpToLiveEdge() {
    LiveEdgeCatchUp.seekIfNeeded(player: player, isStopped: isStopped, fallbackActive: fallbackWebView != nil)
  }

  // 失敗item/通知/タイマー/ウォッチドッグ/ローダーを一掃(再接続・再試行前の後始末)。Codex指摘④。
  private func teardownPlayback() {
    playbackGeneration += 1
    liveCatchUpTimer?.invalidate()
    liveCatchUpTimer = nil
    stallWatchdog.stop()
    lowLatencyLoader = nil
    itemStatusObservation = nil
    if let obs = itemFailedObserver {
      NotificationCenter.default.removeObserver(obs)
      itemFailedObserver = nil
    }
    player.replaceCurrentItem(with: nil)
  }

  // ネイティブ再生失敗の共通処理。web UIへ落とす前に: ①低遅延ローダー失敗→素HLS再試行
  // ②素HLSも失敗(=playback_url/トークン失効の可能性)→チャンネル再取得で新URLを取り直し再生。
  // 上限超過時のみ web UI フォールバック。古い世代の失敗通知は無視。Codex指摘②③。
  private func handleNativeFailure(_ reason: String, wasLowLatency: Bool, generation: Int) {
    DispatchQueue.main.async {
      guard !self.isStopped, self.fallbackWebView == nil,
            generation == self.playbackGeneration else { return }
      if wasLowLatency, let url = self.currentHLSURL {
        self.play(hlsURL: url, lowLatency: false)
        return
      }
      if let attempt = self.nativeRetry.nextAttempt() {
        self.teardownPlayback()
        self.channelTask?.cancel()
        self.channelTask = nil
        self.isLoading = false
        self.showStatus("Kick再接続中(\(attempt)/\(self.nativeRetry.maxAttempts))")
        self.loadNativeStream()
        return
      }
      self.installFallback(reason)
    }
  }

  // 安定モードで一定時間ストール無しなら低遅延へ自動復帰(ネットワーク回復時)。次回再接続からLL有効。
  private func scheduleStableModeReset() {
    guard stableMode else { return }
    stallCountResetWork?.cancel()
    stallCountResetWork = nil
    stableModeResetWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.isStopped else { return }
      self.stableMode = false
      self.stallCount = 0
    }
    stableModeResetWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
  }

  private func scheduleStallCountReset() {
    guard !stableMode, stallCount > 0 else { return }
    stallCountResetWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.isStopped, !self.stableMode else { return }
      self.stallCount = 0
    }
    stallCountResetWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
  }

  // ストール検知時のネイティブ再接続(webviewフォールバックではなく Kick HLS を取り直す)。
  private func recoverFromStall() {
    guard !isStopped, fallbackWebView == nil else { return }
    stallCount += 1
    if stallCount >= 2 {
      stableMode = true        // 連続ストール→安定モードへ
      stallCountResetWork?.cancel()
      stallCountResetWork = nil
    } else {
      scheduleStallCountReset()
    }
    stableModeResetWork?.cancel()
    showStatus(stableMode ? "再生が不安定なため安定モードで再接続中" : "再生が止まったため再接続中")
    teardownPlayback()
    channelTask?.cancel()
    channelTask = nil
    isLoading = false
    loadNativeStream()
  }

  private func installFallback(_ reason: String) {
    DispatchQueue.main.async {
      guard !self.isStopped, self.fallbackWebView == nil else { return }
      // ネイティブ再生を完全停止してから web UI へ(失敗item/timer/watchdog/loaderの残留を防ぐ・Codex指摘)。
      self.liveCatchUpTimer?.invalidate()
      self.liveCatchUpTimer = nil
      self.stallWatchdog.stop()
      self.lowLatencyLoader = nil
      self.player.pause()
      self.player.replaceCurrentItem(with: nil)
      self.itemStatusObservation = nil
      if let obs = self.itemFailedObserver {
        NotificationCenter.default.removeObserver(obs)
        self.itemFailedObserver = nil
      }
      self.showStatus(reason)
      let web = PlayerWebView(stream: self.stream, settings: self.settings)
      web.setPlaybackVolume(self.playbackVolume)
      web.translatesAutoresizingMaskIntoConstraints = false
      self.insertSubview(web, belowSubview: self.statusLabel)
      NSLayoutConstraint.activate([
        web.topAnchor.constraint(equalTo: self.topAnchor),
        web.leadingAnchor.constraint(equalTo: self.leadingAnchor),
        web.trailingAnchor.constraint(equalTo: self.trailingAnchor),
        web.bottomAnchor.constraint(equalTo: self.bottomAnchor)
      ])
      self.fallbackWebView = web
      self.socketTask?.cancel(with: .goingAway, reason: nil)
      self.socketTask = nil
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        web.resumePlayback()
      }
    }
  }

  private func showStatus(_ text: String) {
    DispatchQueue.main.async {
      self.statusLabel.text = text
      self.statusLabel.isHidden = false
    }
  }

  private func kickHeaders() -> [String: String] {
    var headers = [
      "Accept": "application/json, text/plain, */*",
      "User-Agent": Self.userAgent,
      "Referer": "https://kick.com/\(stream.channel)",
      "Origin": "https://kick.com"
    ]
    if let cookie = kickCookieHeader() {
      headers["Cookie"] = cookie
    }
    return headers
  }

  private func kickPlaybackHeaders() -> [String: String] {
    var headers = [
      "User-Agent": Self.userAgent,
      "Referer": "https://kick.com/\(stream.channel)",
      "Origin": "https://kick.com"
    ]
    if let cookie = kickCookieHeader() {
      headers["Cookie"] = cookie
    }
    return headers
  }

  private func kickCookieHeader() -> String? {
    let urls = [
      URL(string: "https://kick.com/"),
      URL(string: "https://www.kick.com/"),
      URL(string: "https://api.kick.com/")
    ].compactMap { $0 }
    var cookies = urls.flatMap { HTTPCookieStorage.shared.cookies(for: $0) ?? [] }
    cookies.append(contentsOf: HTTPCookieStorage.shared.cookies?.filter { $0.domain.contains("kick.com") } ?? [])
    var seen = Set<String>()
    let unique = cookies.filter { cookie in
      let key = "\(cookie.name)=\(cookie.value)"
      guard !seen.contains(key) else { return false }
      seen.insert(key)
      return true
    }
    guard !unique.isEmpty else { return nil }
    return unique.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
  }

  private func syncKickWebCookies(_ completion: @escaping () -> Void) {
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
      cookies
        .filter { $0.domain.contains("kick.com") }
        .forEach { HTTPCookieStorage.shared.setCookie($0) }
      DispatchQueue.main.async(execute: completion)
    }
  }

  private func connectKickComments(chatroomID: String) {
    guard (settings.showChat || settings.autoFollowRaids), !isStopped else { return }
    self.chatroomID = chatroomID
    socketTask?.cancel(with: .goingAway, reason: nil)
    guard let url = URL(string: "wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679?protocol=7&client=ios-native&version=1.0&flash=false") else { return }
    let task = URLSession.shared.webSocketTask(with: url)
    socketTask = task
    task.resume()
    // Chat messages arrive on the chatroom channel; host/raid (ChatMove…) and
    // other channel events arrive on the channel's own Pusher channel, so
    // subscribe to both.
    var channels = ["chatrooms.\(chatroomID).v2"]
    if let channelID = kickChannelID, !channelID.isEmpty {
      channels.append("channel.\(channelID)")
    }
    for channelName in channels {
      let payload: [String: Any] = [
        "event": "pusher:subscribe",
        "data": ["auth": "", "channel": channelName]
      ]
      if let data = try? JSONSerialization.data(withJSONObject: payload),
         let text = String(data: data, encoding: .utf8) {
        task.send(.string(text)) { _ in }
      }
    }
    receiveKickComment()
  }

  private func receiveKickComment() {
    socketTask?.receive { [weak self] result in
      guard let self, !self.isStopped else { return }
      switch result {
      case .failure:
        self.socketTask?.cancel(with: .goingAway, reason: nil)
        self.socketTask = nil
        if let chatroomID = self.chatroomID {
          DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.connectKickComments(chatroomID: chatroomID)
          }
        }
      case .success(let message):
        if case .string(let text) = message {
          self.handleKickSocketMessage(text)
        }
        self.receiveKickComment()
      }
    }
  }

  private func handleKickSocketMessage(_ text: String) {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let event = json["event"] as? String else { return }
    if event == "pusher:ping" {
      socketTask?.send(.string(#"{"event":"pusher:pong","data":{}}"#)) { _ in }
      return
    }
    let payloadData: Data?
    if let raw = json["data"] as? String {
      payloadData = raw.data(using: .utf8)
    } else if let raw = json["data"] as? [String: Any] {
      payloadData = try? JSONSerialization.data(withJSONObject: raw)
    } else {
      payloadData = nil
    }
    guard let payloadData,
          let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { return }
    // Auto-follow a raid/host ONLY from Kick's explicit host/raid events. Chat text
    // は走査しない (誤検知の元)。Kick はイベント名を時々変えるので、Raid/Host を
    // 含む event class を網羅的に拾うようにしている。
    let normalizedEvent = event.lowercased()
    let raidEventKeywords = ["chatmovetosupportedchannel", "streamhost", "streamhosted", "streamraid", "raidevent", "hostevent", "chatroomraid"]
    if raidEventKeywords.contains(where: { normalizedEvent.contains($0) }) {
      // `hosted`/destination is the channel being hosted: the raid target when our
      // channel raids out, or our own channel on an incoming host (which
      // RaidAutoFollow.follow ignores — so an incoming host never makes us jump).
      if settings.autoFollowRaids, let target = Self.kickHostTarget(in: payload) {
        RaidAutoFollow.follow(platform: .kick, channel: target, currentChannel: stream.channel)
      }
      return
    }
    if let alert = Self.kickSupportAlert(event: event, payload: payload) {
      // サブ/ギフトはニコ生と同じリッチ表示(アイコン+バースト+音)に格上げ。テキストバナーから変更。
      NativeGiftSoundMixer.shared.play(style: .gift, enabled: settings.giftSoundEnabled, volume: playbackVolume)
      NativeEventOverlay.showSupport(
        title: alert,
        subtitle: nil,
        symbolName: NativeGiftEffectStyle.gift.heroSymbol,
        progress: nil,
        effectStyle: .gift,
        assetImage: nil,
        in: danmakuView,
        tint: StreamPlatform.kick.tint
      )
      return
    }
    guard event.contains("ChatMessage"),
          let content = (payload["content"] as? String) ?? (payload["message"] as? String) else { return }
    if settings.showChat {
      let tokens = Self.kickDanmakuTokens(content)
      let filterText = Self.kickFilterText(content)
      emitDanmaku(tokens, filterText: filterText)
    }
  }

  private func emitDanmaku(_ tokens: [NativeDanmakuToken], filterText: String) {
    DispatchQueue.main.async {
      self.laneCursor = NativeDanmakuRenderer.emit(
        tokens: tokens,
        filterText: filterText,
        in: self.danmakuView,
        laneCursor: self.laneCursor,
        settings: self.settings
      )
    }
  }

  func emitOwnComment(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    DispatchQueue.main.async {
      self.laneCursor = NativeDanmakuRenderer.emit(
        tokens: NativeDanmakuRenderer.textTokens(trimmed),
        filterText: trimmed,
        in: self.danmakuView,
        laneCursor: self.laneCursor,
        settings: self.settings,
        highlighted: true
      )
    }
  }

  private static func kickDanmakuTokens(_ content: String) -> [NativeDanmakuToken] {
    let pattern = #"\[emote:(\d+):([^\]]+)\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [.text(content)] }
    let range = NSRange(content.startIndex..<content.endIndex, in: content)
    var tokens: [NativeDanmakuToken] = []
    var cursor = content.startIndex
    for match in regex.matches(in: content, range: range) {
      guard let fullRange = Range(match.range(at: 0), in: content),
            let idRange = Range(match.range(at: 1), in: content) else { continue }
      if cursor < fullRange.lowerBound {
        tokens.append(.text(String(content[cursor..<fullRange.lowerBound])))
      }
      let id = String(content[idRange])
      if let url = URL(string: "https://files.kick.com/emotes/\(id)/fullsize") {
        tokens.append(.image(url))
      }
      cursor = fullRange.upperBound
    }
    if cursor < content.endIndex {
      tokens.append(.text(String(content[cursor..<content.endIndex])))
    }
    return tokens.isEmpty ? [.text(content)] : tokens
  }

  private static func kickFilterText(_ content: String) -> String {
    let pattern = #"\[emote:(\d+):([^\]]+)\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
    var output = content
    for match in regex.matches(in: output, range: NSRange(output.startIndex..<output.endIndex, in: output)).reversed() {
      guard let fullRange = Range(match.range(at: 0), in: output),
            let nameRange = Range(match.range(at: 2), in: output) else { continue }
      let name = String(output[nameRange])
      output.replaceSubrange(fullRange, with: name)
    }
    return output
  }

  private static func kickSupportAlert(event: String, payload: [String: Any]) -> String? {
    let lower = event.lowercased()
    guard !lower.contains("chatmessage") else { return nil }
    if (payload["isTest"] as? Bool) == true { return nil }
    let eventName = event.split(separator: "\\").last.map(String.init) ?? event
    let normalized = eventName.lowercased()
    let isGift = normalized == "kick.giftsubscription"
      || normalized == "giftsubscription"
      || normalized == "giftsubscriptionevent"
      || normalized == "giftedsubscriptionevent"
      || normalized == "giftedsubscriptionsevent"
      || normalized == "luckyuserswhogotgiftsubscriptionsevent"
    let isSubscription = normalized == "channelsubscriptionevent"
      || normalized == "subscriptionevent"
      || normalized == "kick.subscription"
      || normalized == "subscription"
    guard isGift || isSubscription else { return nil }
    let user = payload["user"] as? [String: Any]
    let gifter = payload["gifter"] as? [String: Any]
    let recipientObject = payload["recipient"] as? [String: Any]
    let actor = firstString([
      payload["username"],
      payload["login"],
      payload["name"],
      payload["gifter_username"],
      payload["gifter"],
      payload["sender"],
      user?["username"],
      user?["login"],
      user?["name"],
      gifter?["username"],
      gifter?["login"],
      gifter?["name"]
    ]) ?? ((payload["isAnonymous"] as? Bool) == true ? "匿名" : nil)
    guard let actor else { return nil }
    let recipient = firstString([
      payload["recipient_username"],
      payload["recipient_login"],
      payload["recipient_name"],
      recipientObject?["username"],
      recipientObject?["login"],
      recipientObject?["name"],
      user?["username"],
      user?["login"],
      user?["name"]
    ])
    let count = firstString([
      payload["gifted_quantity"],
      payload["quantity"],
      payload["count"]
    ])
    if isGift {
      if let count, count != "0" {
        return "Kick: \(actor) が \(count) 件のサブスクをギフト"
      }
      if let recipient {
        return "Kick: \(actor) が \(recipient) にサブスクをギフト"
      }
      return "Kick: \(actor) がサブスクをギフト"
    }
    return "Kick: \(actor) がサブスクしました"
  }

  // The channel being hosted/raided-to, taken from the official Kick host-event
  // payload shapes: StreamHostEvent has a `hosted` object; the chat-move event has
  // a destination `channel` object. `host_username` (the source) is intentionally
  // ignored. Never scans free text, so it cannot pick up a wrong channel name.
  private static func kickHostTarget(in payload: [String: Any]) -> String? {
    // 公式 Kick ペイロードでホスト/レイド先が入る箇所のキー名は版で揺れる:
    // StreamHostEvent.hosted, ChatMoveToSupportedChannelEvent.channel, RaidEvent.target_channel など。
    let nestedKeys = ["hosted", "channel", "target_channel", "raid_target", "target", "destination", "to_channel", "host"]
    for key in nestedKeys {
      if let nested = payload[key] as? [String: Any] {
        for slugKey in ["slug", "username", "name"] {
          if let slug = nested[slugKey] as? String, !slug.isEmpty {
            return slug
          }
        }
      }
      if let slug = payload[key] as? String, !slug.isEmpty {
        return slug
      }
    }
    for directKey in ["slug", "target_slug", "host_slug"] {
      if let slug = payload[directKey] as? String, !slug.isEmpty {
        return slug
      }
    }
    return nil
  }

  private static func extractChannelInfo(from data: Data) -> (hlsURL: URL?, chatroomID: String?, channelID: String?) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil, nil) }
    var hlsURL: URL?
    var chatroomID: String?
    var channelID: String?
    if let idValue = json["id"] {
      channelID = Self.stringValue(idValue)
    }
    if channelID == nil,
       let livestream = json["livestream"] as? [String: Any],
       let cid = livestream["channel_id"] {
      channelID = Self.stringValue(cid)
    }
    if let raw = json["playback_url"] as? String {
      hlsURL = URL(string: raw)
    }
    if let livestream = json["livestream"] as? [String: Any],
       let raw = livestream["playback_url"] as? String,
       let url = URL(string: raw) {
      hlsURL = url
    }
    if let chatroom = json["chatroom"] as? [String: Any],
       let id = chatroom["id"] {
      chatroomID = Self.stringValue(id)
    }
    if chatroomID == nil {
      chatroomID = Self.stringValue(json["chatroom_id"] ?? json["chatroomId"])
    }
    if chatroomID == nil,
       let livestream = json["livestream"] as? [String: Any],
       let chatroom = livestream["chatroom"] as? [String: Any],
       let id = chatroom["id"] {
      chatroomID = Self.stringValue(id)
    }
    if chatroomID == nil,
       let livestream = json["livestream"] as? [String: Any] {
      chatroomID = Self.stringValue(livestream["chatroom_id"] ?? livestream["chatroomId"])
    }
    return (hlsURL, chatroomID, channelID)
  }

  private static func extractChatroomID(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return extractChatroomID(from: json)
  }

  private static func extractChatroomID(from value: Any) -> String? {
    if let dict = value as? [String: Any] {
      if let id = stringValue(dict["id"] ?? dict["chatroom_id"] ?? dict["chatroomId"]) {
        return id
      }
      if let chatroom = dict["chatroom"], let id = extractChatroomID(from: chatroom) {
        return id
      }
      if let data = dict["data"], let id = extractChatroomID(from: data) {
        return id
      }
    }
    if let array = value as? [Any] {
      for item in array {
        if let id = extractChatroomID(from: item) {
          return id
        }
      }
    }
    return nil
  }

  private static func stringValue(_ value: Any) -> String? {
    if let string = value as? String { return string }
    if let int = value as? Int { return String(int) }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }

  private static func firstString(_ values: [Any?]) -> String? {
    for value in values {
      guard let value, let text = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
        continue
      }
      return text
    }
    return nil
  }

  private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
}

// Native Twitch playback, emulating the official app: fetch a PlaybackAccessToken
// over GraphQL, build the usher.ttvnw.net HLS master playlist, and play it with
// AVPlayer. Anonymous IRC supplies danmaku comments. Falls back to the web embed.
final class TwitchNativePlayerView: UIView, PlaybackResumable, PlaybackStoppable, AudioControllable, CommentPostable, CommentEchoDisplay {
  private let stream: StreamItem
  private let settings: AppSettings
  private let player = AVPlayer()
  private let playerLayer = AVPlayerLayer()
  private let danmakuView = UIView()
  private let statusLabel = UILabel()
  private var playbackVolume: Float
  private var tokenTask: URLSessionDataTask?
  private var chatSocket: URLSessionWebSocketTask?
  private var chatChannel: String?
  private lazy var stallWatchdog = StallWatchdog(player: player) { [weak self] in
    self?.recoverFromStall()
  }
  private var itemStatusObservation: NSKeyValueObservation?
  private var itemFailedObserver: NSObjectProtocol?
  private var liveCatchUpTimer: Timer?
  private var fallbackWebView: PlayerWebView?
  private var playbackGeneration = 0
  private let nativeRetry = NativeRetryLimiter(maxAttempts: 2)
  private var isLoading = false
  private var isStopped = false
  private var laneCursor = 0

  private static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
  private static let accessTokenHash = "0828119ded1c13477966434e15800ff57ddacf13ba1911c129dc2200705b0712"
  private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"

  init(stream: StreamItem, settings: AppSettings) {
    self.stream = stream
    self.settings = settings
    self.playbackVolume = StreamVolumeStore.volume(for: stream)
    super.init(frame: .zero)
    backgroundColor = .black

    player.automaticallyWaitsToMinimizeStalling = false
    player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    playerLayer.player = player
    playerLayer.videoGravity = .resizeAspect
    layer.addSublayer(playerLayer)

    danmakuView.isUserInteractionEnabled = false
    danmakuView.clipsToBounds = true
    addSubview(danmakuView)

    statusLabel.text = "Twitchをネイティブ再生で読み込み中"
    statusLabel.textColor = .white.withAlphaComponent(0.72)
    statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 2
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(statusLabel)
    NSLayoutConstraint.activate([
      statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
    ])

    PlaybackCoordinator.shared.register(self)
    loadNativeStream()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    stopPlayback()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    playerLayer.frame = bounds
    danmakuView.frame = bounds
  }

  func resumePlayback() {
    guard !isStopped else { return }
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default, options: [])
    try? session.setActive(true)
    if let fallbackWebView {
      fallbackWebView.resumePlayback()
      return
    }
    if player.currentItem == nil {
      loadNativeStream()
      return
    }
    player.isMuted = !settings.playAudio
    player.volume = settings.playAudio ? playbackVolume : 0
    player.play()
  }

  func pausePlayback() {
    player.pause()
    fallbackWebView?.pausePlayback()
  }

  private func recoverFromStall() {
    guard !isStopped, fallbackWebView == nil else { return }
    showStatus("Twitch再接続中")
    teardownPlayback()
    tokenTask?.cancel()
    tokenTask = nil
    isLoading = false
    loadNativeStream()
  }

  func stopPlayback() {
    isStopped = true
    stallWatchdog.stop()
    liveCatchUpTimer?.invalidate()
    liveCatchUpTimer = nil
    tokenTask?.cancel()
    tokenTask = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    chatSocket?.cancel(with: .goingAway, reason: nil)
    chatSocket = nil
    chatChannel = nil
    fallbackWebView?.stopPlayback()
    fallbackWebView?.removeFromSuperview()
    fallbackWebView = nil
    itemStatusObservation = nil
    if let itemFailedObserver {
      NotificationCenter.default.removeObserver(itemFailedObserver)
      self.itemFailedObserver = nil
    }
  }

  func setPlaybackVolume(_ volume: Float) {
    playbackVolume = min(1, max(0, volume))
    player.volume = settings.playAudio ? playbackVolume : 0
    fallbackWebView?.setPlaybackVolume(playbackVolume)
  }

  func postComment(_ text: String, completion: @escaping (Result<Void, Error>) -> Void) {
    TwitchAuthManager.shared.sendChat(channel: stream.channel, content: text, completion: completion)
  }

  private func loadNativeStream() {
    guard !isStopped, !isLoading, fallbackWebView == nil else { return }
    let channel = Self.normalizeChannel(stream.channel)
    guard !channel.isEmpty else {
      installFallback("Twitchチャンネル名が不正です")
      return
    }
    isLoading = true
    showStatus("Twitchをネイティブ再生で読み込み中")
    requestAccessToken(channel: channel, generation: playbackGeneration)
  }

  private func requestAccessToken(channel: String, generation: Int) {
    guard let url = URL(string: "https://gql.twitch.tv/gql") else {
      installFallback("Twitch APIに接続できません")
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(Self.clientID, forHTTPHeaderField: "Client-ID")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    let body: [String: Any] = [
      "operationName": "PlaybackAccessToken",
      "extensions": [
        "persistedQuery": [
          "version": 1,
          "sha256Hash": Self.accessTokenHash
        ]
      ],
      "variables": [
        "isLive": true,
        "login": channel,
        "isVod": false,
        "vodID": "",
        "playerType": "embed"
      ]
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    tokenTask = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
      guard let self else { return }
      self.tokenTask = nil
      guard !self.isStopped, generation == self.playbackGeneration else { return }
      if let error {
        self.retryNativeLoadOrFallback("Twitchトークン取得失敗: \(error.localizedDescription)", generation: generation)
        return
      }
      guard let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = json["data"] as? [String: Any],
            let token = payload["streamPlaybackAccessToken"] as? [String: Any],
            let value = token["value"] as? String,
            let signature = token["signature"] as? String else {
        self.retryNativeLoadOrFallback("Twitchの配信情報を取得できません", generation: generation)
        return
      }
      guard let usherURL = Self.buildUsherURL(channel: channel, token: value, signature: signature) else {
        self.retryNativeLoadOrFallback("Twitch再生URLを構築できません", generation: generation)
        return
      }
      DispatchQueue.main.async {
        guard !self.isStopped, generation == self.playbackGeneration, self.fallbackWebView == nil else { return }
        self.isLoading = false
        self.connectTwitchChat(channel: channel)
        self.play(hlsURL: usherURL, requestGeneration: generation)
      }
    }
    tokenTask?.resume()
  }

  private static func buildUsherURL(channel: String, token: String, signature: String) -> URL? {
    guard let pathChannel = channel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          var components = URLComponents(string: "https://usher.ttvnw.net/api/channel/hls/\(pathChannel).m3u8") else {
      return nil
    }
    components.queryItems = [
      URLQueryItem(name: "sig", value: signature),
      URLQueryItem(name: "token", value: token),
      URLQueryItem(name: "allow_source", value: "true"),
      URLQueryItem(name: "allow_audio_only", value: "true"),
      URLQueryItem(name: "player", value: "twitchweb"),
      URLQueryItem(name: "p", value: String(Int.random(in: 0..<1_000_000))),
      URLQueryItem(name: "type", value: "any"),
      URLQueryItem(name: "fast_bread", value: "true"),
      URLQueryItem(name: "playlist_include_framerate", value: "true")
    ]
    return components.url
  }

  private func play(hlsURL: URL, requestGeneration: Int) {
    DispatchQueue.main.async {
      guard !self.isStopped, requestGeneration == self.playbackGeneration,
            self.fallbackWebView == nil else { return }
      self.statusLabel.isHidden = true
      self.playbackGeneration += 1
      let generation = self.playbackGeneration
      let asset = AVURLAsset(url: hlsURL, options: [
        "AVURLAssetHTTPHeaderFieldsKey": self.twitchPlaybackHeaders(),
        // Live HLS never needs a precise duration; skip that analysis to trim startup.
        AVURLAssetPreferPreciseDurationAndTimingKey: false
      ])
      let item = AVPlayerItem(asset: asset)
      item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
      item.preferredPeakBitRate = NetworkQuality.shared.effectivePeakBitRate(settings: self.settings)
      // Twitch(fast_bread LL-HLS)。低遅延優先で2秒(再詰め・ユーザー要望/カクつき改善後)。
      item.configuredTimeOffsetFromLive = CMTime(seconds: 1.5, preferredTimescale: 600)
      item.automaticallyPreservesTimeOffsetFromLive = true
      self.itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
        if item.status == .failed {
          self?.handleNativeFailure(
            item.error?.localizedDescription ?? "Twitchネイティブ再生に失敗しました",
            generation: generation)
        } else if item.status == .readyToPlay {
          DispatchQueue.main.async {
            guard let self, generation == self.playbackGeneration,
                  !self.isStopped, self.fallbackWebView == nil else { return }
            self.nativeRetry.reset()
            self.resumePlayback()
            self.startLiveCatchUp()
            self.stallWatchdog.start()
          }
        }
      }
      if let itemFailedObserver = self.itemFailedObserver {
        NotificationCenter.default.removeObserver(itemFailedObserver)
      }
      self.itemFailedObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemFailedToPlayToEndTime,
        object: item,
        queue: .main
      ) { [weak self] notification in
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
        self?.handleNativeFailure(
          error?.localizedDescription ?? "Twitchネイティブ再生が停止しました",
          generation: generation)
      }
      self.player.replaceCurrentItem(with: item)
      self.player.isMuted = !self.settings.playAudio
      self.player.volume = self.settings.playAudio ? self.playbackVolume : 0
      self.player.play()
    }
  }

  private func startLiveCatchUp() {
    liveCatchUpTimer?.invalidate()
    liveCatchUpTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
      self?.catchUpToLiveEdge()
    }
    catchUpToLiveEdge()
  }

  private func catchUpToLiveEdge() {
    LiveEdgeCatchUp.seekIfNeeded(player: player, isStopped: isStopped, fallbackActive: fallbackWebView != nil)
  }

  private func teardownPlayback() {
    playbackGeneration += 1
    liveCatchUpTimer?.invalidate()
    liveCatchUpTimer = nil
    stallWatchdog.stop()
    itemStatusObservation = nil
    if let obs = itemFailedObserver {
      NotificationCenter.default.removeObserver(obs)
      itemFailedObserver = nil
    }
    player.pause()
    player.replaceCurrentItem(with: nil)
  }

  private func handleNativeFailure(_ reason: String, generation: Int) {
    DispatchQueue.main.async {
      guard !self.isStopped, self.fallbackWebView == nil,
            generation == self.playbackGeneration else { return }
      self.retryNativeLoadOrFallback(reason, generation: generation)
    }
  }

  private func retryNativeLoadOrFallback(_ reason: String, generation: Int? = nil) {
    DispatchQueue.main.async {
      guard !self.isStopped, self.fallbackWebView == nil else { return }
      if let generation, generation != self.playbackGeneration { return }
      if let attempt = self.nativeRetry.nextAttempt() {
        self.teardownPlayback()
        self.tokenTask?.cancel()
        self.tokenTask = nil
        self.isLoading = false
        self.showStatus("Twitch再接続中(\(attempt)/\(self.nativeRetry.maxAttempts))")
        self.loadNativeStream()
        return
      }
      self.installFallback(reason)
    }
  }

  private func installFallback(_ reason: String) {
    DispatchQueue.main.async {
      guard !self.isStopped, self.fallbackWebView == nil else { return }
      self.isLoading = false
      // 失敗item/watchdog/timerを残さない(Codex指摘の停止漏れ修正)。
      self.teardownPlayback()
      self.tokenTask?.cancel()
      self.tokenTask = nil
      self.showStatus(reason)
      let web = PlayerWebView(stream: self.stream, settings: self.settings)
      web.setPlaybackVolume(self.playbackVolume)
      web.translatesAutoresizingMaskIntoConstraints = false
      self.insertSubview(web, belowSubview: self.statusLabel)
      NSLayoutConstraint.activate([
        web.topAnchor.constraint(equalTo: self.topAnchor),
        web.leadingAnchor.constraint(equalTo: self.leadingAnchor),
        web.trailingAnchor.constraint(equalTo: self.trailingAnchor),
        web.bottomAnchor.constraint(equalTo: self.bottomAnchor)
      ])
      self.fallbackWebView = web
      self.chatSocket?.cancel(with: .goingAway, reason: nil)
      self.chatSocket = nil
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        web.resumePlayback()
      }
    }
  }

  private func showStatus(_ text: String) {
    DispatchQueue.main.async {
      self.statusLabel.text = text
      self.statusLabel.isHidden = false
    }
  }

  private func twitchPlaybackHeaders() -> [String: String] {
    [
      "User-Agent": Self.userAgent,
      "Referer": "https://player.twitch.tv/",
      "Origin": "https://player.twitch.tv"
    ]
  }

  private func connectTwitchChat(channel: String) {
    guard (settings.showChat || settings.autoFollowRaids), !isStopped, fallbackWebView == nil else { return }
    chatChannel = channel
    chatSocket?.cancel(with: .goingAway, reason: nil)
    guard let url = URL(string: "wss://irc-ws.chat.twitch.tv:443") else { return }
    let task = URLSession.shared.webSocketTask(with: url)
    chatSocket = task
    task.resume()
    let nick = "justinfan\(Int.random(in: 10000..<1_000_000))"
    task.send(.string("CAP REQ :twitch.tv/tags twitch.tv/commands")) { _ in }
    task.send(.string("PASS SCHMOOPIIE")) { _ in }
    task.send(.string("NICK \(nick)")) { _ in }
    task.send(.string("JOIN #\(channel)")) { _ in }
    receiveTwitchChat()
  }

  private func receiveTwitchChat() {
    chatSocket?.receive { [weak self] result in
      guard let self, !self.isStopped else { return }
      switch result {
      case .failure:
        self.chatSocket?.cancel(with: .goingAway, reason: nil)
        self.chatSocket = nil
        guard let channel = self.chatChannel else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
          guard let self, !self.isStopped, self.fallbackWebView == nil else { return }
          self.connectTwitchChat(channel: channel)
        }
      case .success(let message):
        if case .string(let text) = message {
          self.handleTwitchChat(text)
        }
        self.receiveTwitchChat()
      }
    }
  }

  private func handleTwitchChat(_ text: String) {
    for rawLine in text.components(separatedBy: "\r\n") where !rawLine.isEmpty {
      if rawLine.hasPrefix("PING") {
        chatSocket?.send(.string("PONG :tmi.twitch.tv")) { _ in }
        continue
      }
      var tags: [String: String] = [:]
      var line = rawLine
      if line.hasPrefix("@"), let split = line.firstIndex(of: " ") {
        tags = Self.parseTwitchTags(String(line[line.index(after: line.startIndex)..<split]))
        line = String(line[line.index(after: split)...])
      }
      if settings.autoFollowRaids,
         let target = Self.twitchRaidTarget(from: line, tags: tags) {
        RaidAutoFollow.follow(platform: target.0, channel: target.1, currentChannel: stream.channel)
      }
      if let alert = Self.twitchSupportAlert(from: line, tags: tags) {
        // サブ/ギフトはニコ生・Kickと同じリッチ表示(アイコン+バースト+音)に格上げ。
        NativeGiftSoundMixer.shared.play(style: .gift, enabled: settings.giftSoundEnabled, volume: playbackVolume)
        NativeEventOverlay.showSupport(
          title: alert,
          subtitle: nil,
          symbolName: NativeGiftEffectStyle.gift.heroSymbol,
          progress: nil,
          effectStyle: .gift,
          assetImage: nil,
          in: danmakuView,
          tint: StreamPlatform.twitch.tint
        )
      }
      guard let privmsg = line.range(of: " PRIVMSG "),
            let bodyRange = line.range(of: " :", range: privmsg.lowerBound..<line.endIndex) else { continue }
      let message = String(line[bodyRange.upperBound...])
      // Raids are detected only from USERNOTICE tags above (twitchRaidTarget) — never
      // by scanning chat text, which would jump on ordinary messages mentioning a raid.
      if settings.showChat {
        emitDanmaku(Self.twitchDanmakuTokens(message, emotesTag: tags["emotes"]), filterText: message)
      }
    }
  }

  private static func twitchRaidTarget(from line: String, tags: [String: String]) -> (StreamPlatform, String)? {
    let lower = line.lowercased()
    if lower.contains(" usernotice ") || lower.contains(" notice ") {
      let targetKeys = [
        "msg-param-target-login",
        "msg-param-target_user_login",
        "msg-param-targetuserlogin",
        "msg-param-to-broadcaster-user-login",
        "msg-param-raid-target",
        "msg-param-channel"
      ]
      for key in targetKeys {
        if let value = tags[key], !value.isEmpty {
          return (.twitch, value)
        }
      }
      if let bodyRange = line.range(of: " :"),
         let target = RaidAutoFollow.detectTarget(in: String(line[bodyRange.upperBound...]), preferredPlatform: .twitch) {
        return target
      }
    }
    return nil
  }

  private static func twitchSupportAlert(from line: String, tags: [String: String]) -> String? {
    guard line.lowercased().contains(" usernotice ") else { return nil }
    let id = tags["msg-id"]?.lowercased() ?? ""
    guard id.contains("sub") || id.contains("gift") else { return nil }
    let system = tags["system-msg"]?.replacingOccurrences(of: "\\s", with: " ")
    let sender = tags["display-name"] ?? tags["login"] ?? "誰か"
    if id == "subgift" || id == "submysterygift" || id.contains("gift") {
      let recipient = tags["msg-param-recipient-display-name"] ?? tags["msg-param-recipient-user-name"]
      let count = tags["msg-param-mass-gift-count"] ?? tags["msg-param-sender-count"]
      if let system, !system.isEmpty { return "Twitch: \(system)" }
      if let count, id == "submysterygift" {
        return "Twitch: \(sender) が \(count) 件のサブスクをギフト"
      }
      if let recipient {
        return "Twitch: \(sender) が \(recipient) にサブスクをギフト"
      }
      return "Twitch: \(sender) がサブスクをギフト"
    }
    if id == "sub" || id == "resub" {
      if let system, !system.isEmpty { return "Twitch: \(system)" }
      let months = tags["msg-param-cumulative-months"] ?? tags["msg-param-months"]
      if let months, months != "0" {
        return "Twitch: \(sender) が \(months) か月サブスク"
      }
      return "Twitch: \(sender) がサブスクしました"
    }
    return nil
  }

  private func emitDanmaku(_ tokens: [NativeDanmakuToken], filterText: String) {
    DispatchQueue.main.async {
      self.laneCursor = NativeDanmakuRenderer.emit(
        tokens: tokens,
        filterText: filterText,
        in: self.danmakuView,
        laneCursor: self.laneCursor,
        settings: self.settings
      )
    }
  }

  func emitOwnComment(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    DispatchQueue.main.async {
      self.laneCursor = NativeDanmakuRenderer.emit(
        tokens: NativeDanmakuRenderer.textTokens(trimmed),
        filterText: trimmed,
        in: self.danmakuView,
        laneCursor: self.laneCursor,
        settings: self.settings,
        highlighted: true
      )
    }
  }

  private static func parseTwitchTags(_ raw: String) -> [String: String] {
    var tags: [String: String] = [:]
    raw.split(separator: ";").forEach { pair in
      let rawPair = String(pair)
      guard let eq = rawPair.firstIndex(of: "=") else { return }
      let key = String(rawPair[..<eq])
      let value = String(rawPair[rawPair.index(after: eq)...])
        .replacingOccurrences(of: "\\s", with: " ")
        .replacingOccurrences(of: "\\:", with: ";")
        .replacingOccurrences(of: "\\r", with: "\r")
        .replacingOccurrences(of: "\\n", with: "\n")
      tags[key] = value
    }
    return tags
  }

  private static func twitchDanmakuTokens(_ message: String, emotesTag: String?) -> [NativeDanmakuToken] {
    let chars = Array(message)
    var ranges: [(id: String, start: Int, end: Int)] = []
    emotesTag?.split(separator: "/").forEach { part in
      let pieces = part.split(separator: ":")
      guard pieces.count == 2 else { return }
      let id = String(pieces[0])
      pieces[1].split(separator: ",").forEach { rawRange in
        let bounds = rawRange.split(separator: "-")
        guard bounds.count == 2,
              let start = Int(bounds[0]),
              let end = Int(bounds[1]),
              start >= 0,
              end >= start,
              end < chars.count else { return }
        ranges.append((id, start, end))
      }
    }
    ranges.sort { $0.start < $1.start }
    var tokens: [NativeDanmakuToken] = []
    var cursor = 0
    for range in ranges where range.start >= cursor {
      if cursor < range.start {
        tokens.append(.text(String(chars[cursor..<range.start])))
      }
      if let url = URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(range.id)/default/dark/1.0") {
        tokens.append(.image(url))
      }
      cursor = range.end + 1
    }
    if cursor < chars.count {
      tokens.append(.text(String(chars[cursor..<chars.count])))
    }
    return tokens.isEmpty ? [.text(message)] : tokens
  }

  private static func normalizeChannel(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    value = value.replacingOccurrences(of: "^@+", with: "", options: .regularExpression)
    if let range = value.range(of: "twitch.tv/") {
      value = String(value[range.upperBound...])
    }
    value = value.components(separatedBy: CharacterSet(charactersIn: "/?# ")).first ?? value
    return value
  }
}

final class TwitcastingNativePlayerView: UIView, PlaybackResumable, PlaybackStoppable, AudioControllable, CommentPostable, CommentEchoDisplay {
  private let stream: StreamItem
  private let settings: AppSettings
  private let player = AVPlayer()
  private let playerLayer = AVPlayerLayer()
  private let danmakuView = UIView()
  private let statusLabel = UILabel()
  private var chatClient: TwitcastingChatClient?
  private lazy var stallWatchdog = StallWatchdog(player: player) { [weak self] in
    self?.recoverFromStall()
  }
  private var streamTask: URLSessionDataTask?
  private var itemStatusObservation: NSKeyValueObservation?
  private var itemFailedObserver: NSObjectProtocol?
  private var liveCatchUpTimer: Timer?
  private var fallbackWebView: WKWebView?
  private var playbackGeneration = 0
  private let nativeRetry = NativeRetryLimiter(maxAttempts: 2)
  private var playbackVolume: Float
  private var laneCursor = 0
  private var isLoading = false
  private var isStopped = false

  init(stream: StreamItem, settings: AppSettings) {
    self.stream = stream
    self.settings = settings
    self.playbackVolume = StreamVolumeStore.volume(for: stream)
    super.init(frame: .zero)
    backgroundColor = .black

    player.automaticallyWaitsToMinimizeStalling = false
    player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    playerLayer.player = player
    playerLayer.videoGravity = .resizeAspect
    layer.addSublayer(playerLayer)

    danmakuView.isUserInteractionEnabled = false
    danmakuView.clipsToBounds = true
    addSubview(danmakuView)

    statusLabel.text = "ツイキャスをネイティブ再生で読み込み中"
    statusLabel.textColor = .white.withAlphaComponent(0.72)
    statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 2
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(statusLabel)
    NSLayoutConstraint.activate([
      statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
    ])

    PlaybackCoordinator.shared.register(self)
    loadNativeStream()
    startCommentsIfNeeded()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    stopPlayback()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    playerLayer.frame = bounds
    danmakuView.frame = bounds
  }

  func resumePlayback() {
    guard !isStopped else { return }
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default, options: [])
    try? session.setActive(true)
    if let fallbackWebView {
      fallbackWebView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(m){try{m.play()}catch(e){}});")
      return
    }
    if player.currentItem == nil {
      if !isLoading {
        loadNativeStream()
      }
      return
    }
    player.isMuted = !settings.playAudio
    player.volume = settings.playAudio ? playbackVolume : 0
    player.play()
  }

  func pausePlayback() {
    player.pause()
    fallbackWebView?.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(m){try{m.pause()}catch(e){}});")
  }

  private func recoverFromStall() {
    guard !isStopped, fallbackWebView == nil else { return }
    showStatus("ツイキャス再接続中")
    teardownPlayback()
    streamTask?.cancel()
    streamTask = nil
    isLoading = false
    loadNativeStream()
  }

  func stopPlayback() {
    isStopped = true
    stallWatchdog.stop()
    liveCatchUpTimer?.invalidate()
    liveCatchUpTimer = nil
    chatClient?.stop()
    chatClient = nil
    streamTask?.cancel()
    streamTask = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    itemStatusObservation = nil
    if let itemFailedObserver {
      NotificationCenter.default.removeObserver(itemFailedObserver)
      self.itemFailedObserver = nil
    }
    fallbackWebView?.stopLoading()
    fallbackWebView?.loadHTMLString("", baseURL: nil)
    fallbackWebView?.removeFromSuperview()
    fallbackWebView = nil
  }

  func setPlaybackVolume(_ volume: Float) {
    playbackVolume = min(1, max(0, volume))
    player.volume = settings.playAudio ? playbackVolume : 0
    applyFallbackVolume()
  }

  func postComment(_ text: String, completion: @escaping (Result<Void, Error>) -> Void) {
    TwitcastingAuthManager.shared.sendChat(channel: stream.channel, content: text, completion: completion)
  }

  private func loadNativeStream() {
    guard !isStopped, !isLoading, fallbackWebView == nil else { return }
    isLoading = true
    showStatus("ツイキャスをネイティブ再生で読み込み中")
    let generation = playbackGeneration
    syncTwitcastingWebCookies { [weak self] in
      self?.fetchStreamServer(generation: generation)
    }
  }

  private func fetchStreamServer(generation: Int) {
    guard !isStopped, generation == playbackGeneration else { return }
    let channel = stream.channel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let target = channel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://twitcasting.tv/streamserver.php?target=\(target)&mode=client&player=pc_web") else {
      isLoading = false
      installEmbedFallback("ツイキャスのチャンネル名が不正です")
      return
    }
    var request = URLRequest(url: url)
    twitcastingHeaders().forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    streamTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.streamTask = nil
      guard !self.isStopped, generation == self.playbackGeneration else { return }
      // Keep isLoading true until play()/installEmbedFallback runs on the main
      // queue, so a concurrent resumePlayback() can't kick off a second fetch.
      if let error {
        self.retryNativeLoadOrFallback("ツイキャス取得失敗: \(error.localizedDescription)", generation: generation)
        return
      }
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        self.retryNativeLoadOrFallback("ツイキャス取得失敗: HTTP \(http.statusCode)", generation: generation)
        return
      }
      guard let data, let info = Self.extractStreamInfo(from: data) else {
        self.retryNativeLoadOrFallback("ツイキャスの配信情報を取得できません", generation: generation)
        return
      }
      guard let hlsURL = info.hlsURL else {
        if info.isLive {
          self.retryNativeLoadOrFallback("ツイキャスのHLSを取得できません", generation: generation)
        } else {
          self.installEmbedFallback("ツイキャスはオフラインです")
        }
        return
      }
      // Play the HLS whenever one is advertised. If it is stale, AVPlayer
      // failure first retries native acquisition, then drops to the official embed.
      self.play(hlsURL: hlsURL, requestGeneration: generation)
    }
    streamTask?.resume()
  }

  private func play(hlsURL: URL, requestGeneration: Int) {
    DispatchQueue.main.async {
      self.isLoading = false
      guard !self.isStopped, requestGeneration == self.playbackGeneration,
            self.fallbackWebView == nil else { return }
      self.statusLabel.isHidden = true
      self.playbackGeneration += 1
      let generation = self.playbackGeneration
      var options: [String: Any] = [
        "AVURLAssetHTTPHeaderFieldsKey": self.twitcastingPlaybackHeaders(),
        // Live HLS never needs a precise duration; skip that analysis to trim startup.
        AVURLAssetPreferPreciseDurationAndTimingKey: false
      ]
      // Pass cookies as objects so AVPlayer applies them to every playlist/segment
      // request (a manual Cookie header is not always propagated to sub-requests).
      if let cookieURL = URL(string: "https://twitcasting.tv/"),
         let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL), !cookies.isEmpty {
        options[AVURLAssetHTTPCookiesKey] = cookies
      }
      let asset = AVURLAsset(url: hlsURL, options: options)
      let item = AVPlayerItem(asset: asset)
      item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
      item.preferredPeakBitRate = NetworkQuality.shared.effectivePeakBitRate(settings: self.settings)
      // 低遅延優先で2秒(再詰め)。LL-HLS配信なら効く・通常HLSはno-op。
      item.configuredTimeOffsetFromLive = CMTime(seconds: 1.5, preferredTimescale: 600)
      item.automaticallyPreservesTimeOffsetFromLive = true
      self.itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
        if item.status == .failed {
          self?.handleNativeFailure(
            item.error?.localizedDescription ?? "ツイキャスのネイティブ再生に失敗しました",
            generation: generation)
        } else if item.status == .readyToPlay {
          DispatchQueue.main.async {
            guard let self, generation == self.playbackGeneration,
                  !self.isStopped, self.fallbackWebView == nil else { return }
            self.nativeRetry.reset()
            self.resumePlayback()
            self.startLiveCatchUp()
            self.stallWatchdog.start()
          }
        }
      }
      if let itemFailedObserver = self.itemFailedObserver {
        NotificationCenter.default.removeObserver(itemFailedObserver)
      }
      self.itemFailedObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemFailedToPlayToEndTime,
        object: item,
        queue: .main
      ) { [weak self] notification in
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
        self?.handleNativeFailure(
          error?.localizedDescription ?? "ツイキャスのネイティブ再生が停止しました",
          generation: generation)
      }
      self.player.replaceCurrentItem(with: item)
      self.player.isMuted = !self.settings.playAudio
      self.player.volume = self.settings.playAudio ? self.playbackVolume : 0
      self.player.play()
    }
  }

  private func startLiveCatchUp() {
    liveCatchUpTimer?.invalidate()
    liveCatchUpTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
      self?.catchUpToLiveEdge()
    }
    catchUpToLiveEdge()
  }

  private func catchUpToLiveEdge() {
    LiveEdgeCatchUp.seekIfNeeded(player: player, isStopped: isStopped, fallbackActive: fallbackWebView != nil)
  }

  private func teardownPlayback() {
    playbackGeneration += 1
    liveCatchUpTimer?.invalidate()
    liveCatchUpTimer = nil
    stallWatchdog.stop()
    itemStatusObservation = nil
    if let obs = itemFailedObserver {
      NotificationCenter.default.removeObserver(obs)
      itemFailedObserver = nil
    }
    player.pause()
    player.replaceCurrentItem(with: nil)
  }

  private func handleNativeFailure(_ reason: String, generation: Int) {
    DispatchQueue.main.async {
      guard !self.isStopped, self.fallbackWebView == nil,
            generation == self.playbackGeneration else { return }
      self.retryNativeLoadOrFallback(reason, generation: generation)
    }
  }

  private func retryNativeLoadOrFallback(_ reason: String, generation: Int? = nil) {
    DispatchQueue.main.async {
      guard !self.isStopped, self.fallbackWebView == nil else { return }
      if let generation, generation != self.playbackGeneration { return }
      if let attempt = self.nativeRetry.nextAttempt() {
        self.teardownPlayback()
        self.streamTask?.cancel()
        self.streamTask = nil
        self.isLoading = false
        self.showStatus("ツイキャス再接続中(\(attempt)/\(self.nativeRetry.maxAttempts))")
        self.loadNativeStream()
        return
      }
      self.installEmbedFallback(reason)
    }
  }

  private func applyFallbackVolume() {
    guard let fallbackWebView else { return }
    let effectiveVolume = settings.playAudio ? playbackVolume : 0
    let volumeLiteral = String(Double(effectiveVolume))
    let mutedLiteral = effectiveVolume > 0 ? "false" : "true"
    fallbackWebView.evaluateJavaScript(
      "document.querySelectorAll('video,audio').forEach(function(m){try{m.volume=\(volumeLiteral);m.muted=\(mutedLiteral);}catch(e){}});"
    )
  }

  // Last resort: the official embedded player (handles offline/standby and
  // member-only lives that the native HLS path cannot reach).
  private func installEmbedFallback(_ reason: String) {
    DispatchQueue.main.async {
      self.isLoading = false
      guard !self.isStopped, self.fallbackWebView == nil else { return }
      self.teardownPlayback()
      self.streamTask?.cancel()
      self.streamTask = nil
      self.showStatus(reason)
      let channel = self.stream.channel.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let encoded = channel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            var components = URLComponents(string: "https://twitcasting.tv/\(encoded)/embeddedplayer/live") else { return }
      // Always start the embed muted: WKWebView blocks autoplay-with-sound, so an
      // unmuted embed would just stall (the symptom the user saw). Muted autoplay
      // works; audio is meant to come from the native HLS path anyway.
      components.queryItems = [
        URLQueryItem(name: "auto_play", value: "true"),
        URLQueryItem(name: "default_mute", value: "true")
      ]
      guard let playerURL = components.url else { return }
      let config = WKWebViewConfiguration()
      config.allowsInlineMediaPlayback = true
      config.mediaTypesRequiringUserActionForPlayback = []
      config.websiteDataStore = .default()
      WebAdBlocker.install(on: config)
      if #available(iOS 13.0, *) {
        config.defaultWebpagePreferences.preferredContentMode = .mobile
      }
      let web = WKWebView(frame: .zero, configuration: config)
      web.isOpaque = false
      web.backgroundColor = .black
      web.scrollView.backgroundColor = .black
      web.scrollView.contentInsetAdjustmentBehavior = .never
      web.customUserAgent = Self.userAgent
      web.translatesAutoresizingMaskIntoConstraints = false
      self.insertSubview(web, belowSubview: self.danmakuView)
      NSLayoutConstraint.activate([
        web.topAnchor.constraint(equalTo: self.topAnchor),
        web.leadingAnchor.constraint(equalTo: self.leadingAnchor),
        web.trailingAnchor.constraint(equalTo: self.trailingAnchor),
        web.bottomAnchor.constraint(equalTo: self.bottomAnchor)
      ])
      web.loadHTMLString(Self.embedHTML(playerURL: playerURL), baseURL: URL(string: "https://twitcasting.tv/\(encoded)"))
      self.fallbackWebView = web
      self.statusLabel.isHidden = true
    }
  }

  private func twitcastingHeaders() -> [String: String] {
    var headers = [
      "Accept": "application/json, text/plain, */*",
      "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6",
      "User-Agent": Self.userAgent,
      "Referer": "https://twitcasting.tv/\(stream.channel)",
      "Origin": "https://twitcasting.tv",
      "X-Requested-With": "XMLHttpRequest"
    ]
    if let cookie = cookieHeader() {
      headers["Cookie"] = cookie
    }
    return headers
  }

  private func twitcastingPlaybackHeaders() -> [String: String] {
    // No Origin/Cookie header here: the CDN edge returns 401 (NSURL error -1013)
    // when a cross-origin Origin is present, and cookies are supplied to the asset
    // via AVURLAssetHTTPCookiesKey instead so they reach every sub-request.
    [
      "User-Agent": Self.userAgent,
      "Referer": "https://twitcasting.tv/\(stream.channel)"
    ]
  }

  private func cookieHeader() -> String? {
    guard let url = URL(string: "https://twitcasting.tv/"),
          let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty else { return nil }
    return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
  }

  private func syncTwitcastingWebCookies(_ completion: @escaping () -> Void) {
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
      cookies
        .filter { $0.domain.contains("twitcasting.tv") }
        .forEach { HTTPCookieStorage.shared.setCookie($0) }
      DispatchQueue.main.async(execute: completion)
    }
  }

  private func startCommentsIfNeeded() {
    guard settings.showChat else { return }
    chatClient = TwitcastingChatClient(channel: stream.channel) { [weak self] message, _ in
      self?.emitDanmaku(message)
    }
  }

  private func emitDanmaku(_ text: String) {
    DispatchQueue.main.async {
      self.laneCursor = NativeDanmakuRenderer.emit(
        tokens: NativeDanmakuRenderer.textTokens(text),
        filterText: text,
        in: self.danmakuView,
        laneCursor: self.laneCursor,
        settings: self.settings
      )
    }
  }

  func emitOwnComment(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    DispatchQueue.main.async {
      self.laneCursor = NativeDanmakuRenderer.emit(
        tokens: NativeDanmakuRenderer.textTokens(trimmed),
        filterText: trimmed,
        in: self.danmakuView,
        laneCursor: self.laneCursor,
        settings: self.settings,
        highlighted: true
      )
    }
  }

  private func showStatus(_ text: String) {
    DispatchQueue.main.async {
      self.statusLabel.text = text
      self.statusLabel.isHidden = false
    }
  }

  // Parse twitcasting.tv/streamserver.php JSON: movie.live + the tc-hls media URL.
  private static func extractStreamInfo(from data: Data) -> (isLive: Bool, hlsURL: URL?)? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    var isLive = false
    if let movie = json["movie"] as? [String: Any] {
      if let live = movie["live"] as? Bool {
        isLive = live
      } else if let live = movie["live"] as? Int {
        isLive = live != 0
      }
    }
    var hlsURL: URL?
    if let tcHls = json["tc-hls"] as? [String: Any],
       let streams = tcHls["streams"] as? [String: Any] {
      // Prefer a mid quality for multi-stream performance; AVPlayerItem's
      // preferredPeakBitRate cannot downswitch a single-rendition media playlist.
      let priority = ["medium", "high", "low", "base", "mobilesource", "main"]
      var raw: String?
      for key in priority {
        if let value = streams[key] as? String, !value.isEmpty {
          raw = value
          break
        }
      }
      if raw == nil {
        raw = streams.values.compactMap { $0 as? String }.first { !$0.isEmpty }
      }
      if let raw {
        hlsURL = URL(string: raw)
      }
    }
    return (isLive, hlsURL)
  }

  private static func embedHTML(playerURL: URL) -> String {
    """
    <!doctype html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
      <style>
        html,body,#root,iframe{margin:0;width:100%;height:100%;background:#000;overflow:hidden;border:0;}
      </style>
    </head>
    <body>
      <div id="root">
        <iframe src="\(playerURL.absoluteString)" allow="autoplay; fullscreen; encrypted-media; picture-in-picture" allowfullscreen playsinline></iframe>
      </div>
    </body>
    </html>
    """
  }

  private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
}

// Per-cell YouTube playback first tries native HLS via InnerTube, then falls back
// to the official iframe. Older Worker/WebView/Piped extraction paths were removed
// because they were no longer called and only added startup/network noise.
final class YouTubeNativePlayerView: UIView, PlaybackResumable, PlaybackStoppable, AudioControllable, CommentPostable, CommentEchoDisplay, WKNavigationDelegate, WKScriptMessageHandler {
  private static let instances = NSHashTable<YouTubeNativePlayerView>.weakObjects()
  private let stream: StreamItem
  private let settings: AppSettings
  private let player = AVPlayer()
  private let playerLayer = AVPlayerLayer()
  private let danmakuView = UIView()
  private let statusLabel = UILabel()
  private var playbackVolume: Float
  private var resolveTask: URLSessionDataTask?
  private var sponsorTask: URLSessionDataTask?
  private var chatPollWorkItem: DispatchWorkItem?
  private var itemStatusObservation: NSKeyValueObservation?
  private var timeObserver: Any?
  private var sponsorSegments: [(start: Double, end: Double)] = []
  private var fallbackWebView: WKWebView?
  private var isStopped = false
  private var iframeAudioEnabled = false
  private var liveChatID: String?
  private var liveChatAccessToken: String?
  private var liveChatPageToken: String?
  private var seenLiveChatMessageIDs = Set<String>()
  // YouTube live chat is polled (batches arrive every few seconds). Queue them and
  // drip one at a time so a batch doesn't stampede the screen all at once.
  private var pendingChatMessages: [YouTubeLiveChatMessage] = []
  private var chatDripWorkItem: DispatchWorkItem?
  private var lastChatPollInterval: TimeInterval = 5
  private var laneCursor = 0
  private var extractionFailures: [String] = []

  init(stream: StreamItem, settings: AppSettings) {
    self.stream = stream
    self.settings = settings
    let storedVolume = StreamVolumeStore.volume(for: stream)
    self.playbackVolume = storedVolume <= 0 ? 1 : storedVolume
    self.iframeAudioEnabled = true
    super.init(frame: .zero)
    backgroundColor = .black

    playerLayer.player = player
    playerLayer.videoGravity = .resizeAspect
    player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    player.automaticallyWaitsToMinimizeStalling = false
    layer.addSublayer(playerLayer)

    danmakuView.isUserInteractionEnabled = false
    danmakuView.clipsToBounds = true
    danmakuView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(danmakuView)

    statusLabel.text = "YouTubeを読み込み中"
    statusLabel.textColor = .white.withAlphaComponent(0.72)
    statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 2
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(statusLabel)
    NSLayoutConstraint.activate([
      danmakuView.leadingAnchor.constraint(equalTo: leadingAnchor),
      danmakuView.trailingAnchor.constraint(equalTo: trailingAnchor),
      danmakuView.topAnchor.constraint(equalTo: topAnchor),
      danmakuView.bottomAnchor.constraint(equalTo: bottomAnchor),
      statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
    ])
    PlaybackCoordinator.shared.register(self)
    Self.instances.add(self)
    loadPlayer()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    Self.instances.remove(self)
    stopPlayback()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    playerLayer.frame = bounds
    fallbackWebView?.frame = bounds
  }

  func resumePlayback() {
    guard !isStopped else { return }
    if let fallbackWebView {
      let effective = iframeEffectiveVolume()
      fallbackWebView.evaluateJavaScript("window.mvSetVolume && window.mvSetVolume(\(effective)); window.mvPlay && window.mvPlay();")
      return
    }
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default, options: [])
    try? session.setActive(true)
    applyVolume()
    player.play()
  }

  func pausePlayback() {
    guard !isStopped else { return }
    player.pause()
    fallbackWebView?.evaluateJavaScript("window.mvPause && window.mvPause();")
  }

  func setPlaybackVolume(_ volume: Float) {
    playbackVolume = min(1, max(0, volume))
    iframeAudioEnabled = true
    if iframeAudioEnabled {
      Self.focusAudio(on: self)
    }
    applyVolume()
    fallbackWebView?.evaluateJavaScript("window.mvSetVolume && window.mvSetVolume(\(iframeEffectiveVolume()));")
  }

  private func applyVolume() {
    player.isMuted = false
    player.volume = max(0.01, playbackVolume)
  }

  private func iframeEffectiveVolume() -> Float {
    iframeAudioEnabled ? max(0.01, playbackVolume) : 0
  }

  private static func focusAudio(on active: YouTubeNativePlayerView) {
    for object in instances.allObjects where object !== active {
      object.muteIframeAudio()
    }
  }

  private func muteIframeAudio() {
    iframeAudioEnabled = false
    fallbackWebView?.evaluateJavaScript("window.mvSetVolume && window.mvSetVolume(0);")
  }

  func postComment(_ text: String, completion: @escaping (Result<Void, Error>) -> Void) {
    YouTubeAuthManager.shared.sendChat(channel: stream.channel, content: text, completion: completion)
  }

  func emitOwnComment(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    DispatchQueue.main.async {
      self.laneCursor = NativeDanmakuRenderer.emit(
        tokens: NativeDanmakuRenderer.textTokens(trimmed),
        filterText: trimmed,
        in: self.danmakuView,
        laneCursor: self.laneCursor,
        settings: self.settings,
        highlighted: true
      )
    }
  }

  private func startLiveChatPolling(videoId: String) {
    guard settings.showChat else { return }
    chatPollWorkItem?.cancel(); chatPollWorkItem = nil
    liveChatID = nil
    liveChatAccessToken = nil
    liveChatPageToken = nil
    seenLiveChatMessageIDs.removeAll()
    pendingChatMessages.removeAll()
    chatDripWorkItem?.cancel(); chatDripWorkItem = nil
    YouTubeAuthManager.shared.resolveLiveChat(videoID: videoId) { [weak self] result in
      guard let self, !self.isStopped else { return }
      switch result {
      case .failure(let error):
        self.showStatus(error.localizedDescription)
      case .success(let chat):
        self.liveChatID = chat.liveChatID
        self.liveChatAccessToken = chat.accessToken
        self.pollLiveChat()
      }
    }
  }

  private func pollLiveChat() {
    guard settings.showChat,
          !isStopped,
          let liveChatID else { return }
    // token は毎回自動更新(Codex#2)。固定 token のままだと長時間視聴で 401→停止していた。
    YouTubeAuthManager.shared.fetchLiveChatMessagesRefreshing(
      liveChatID: liveChatID,
      pageToken: liveChatPageToken
    ) { [weak self] result in
      guard let self, !self.isStopped else { return }
      switch result {
      case .failure(let error):
        self.showStatus(error.localizedDescription)
        self.scheduleLiveChatPoll(after: 10)
      case .success(let page):
        self.liveChatPageToken = page.nextPageToken
        let delay = max(2.0, Double(page.pollingIntervalMillis) / 1000.0)
        self.lastChatPollInterval = delay
        self.emitLiveChatMessages(page.messages)
        self.scheduleLiveChatPoll(after: delay)
      }
    }
  }

  private func scheduleLiveChatPoll(after delay: TimeInterval) {
    chatPollWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.pollLiveChat()
    }
    chatPollWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func emitLiveChatMessages(_ messages: [YouTubeLiveChatMessage]) {
    let fresh = messages.filter { !seenLiveChatMessageIDs.contains($0.id) }
    guard !fresh.isEmpty else { return }
    fresh.forEach { seenLiveChatMessageIDs.insert($0.id) }
    // Trim the dedupe set without fully clearing it — a full reset let the very next
    // poll re-show messages whose IDs were just forgotten. Keep the current batch's IDs.
    if seenLiveChatMessageIDs.count > 2000 {
      seenLiveChatMessageIDs = Set(fresh.map { $0.id })
    }
    // Super Chat / メンバー加入 は投げ銭系としてニコ生風のリッチ表示で即時に出す。通常チャットは弾幕へ。
    fresh.filter { $0.superInfo != nil }.forEach { emitYouTubeSuperChat($0) }
    pendingChatMessages.append(contentsOf: fresh.filter { $0.superInfo == nil })
    // A long stall can return a big backlog; cap it so we don't drip hundreds slowly.
    if pendingChatMessages.count > 80 {
      pendingChatMessages.removeFirst(pendingChatMessages.count - 80)
    }
    if chatDripWorkItem == nil {
      dripNextChatMessage()
    }
  }

  private func emitYouTubeSuperChat(_ message: YouTubeLiveChatMessage) {
    NativeGiftSoundMixer.shared.play(style: .premiumGift, enabled: settings.giftSoundEnabled, volume: playbackVolume)
    NativeEventOverlay.showSupport(
      title: "\(message.author): \(message.superInfo ?? "Super Chat")",
      subtitle: message.text.isEmpty ? nil : message.text,
      symbolName: NativeGiftEffectStyle.premiumGift.heroSymbol,
      progress: nil,
      effectStyle: .premiumGift,
      assetImage: nil,
      in: danmakuView,
      tint: StreamPlatform.youtube.tint
    )
  }

  // Emit one queued message, then schedule the next so a polled batch is spread over
  // roughly one poll interval instead of all appearing at the same instant.
  private func dripNextChatMessage() {
    chatDripWorkItem = nil
    guard !isStopped, settings.showChat, !pendingChatMessages.isEmpty else { return }
    let message = pendingChatMessages.removeFirst()
    laneCursor = NativeDanmakuRenderer.emit(
      tokens: NativeDanmakuRenderer.textTokens(message.text),
      filterText: message.text,
      in: danmakuView,
      laneCursor: laneCursor,
      settings: settings
    )
    guard !pendingChatMessages.isEmpty else { return }
    // Cap the emit rate to what the danmaku lanes can hold (lane count × one comment's
    // screen-crossing time). A busy chat polled in big batches otherwise exceeds lane
    // capacity and comments overlap on the same lane.
    let laneCapacity: TimeInterval = {
      let width = danmakuView.bounds.width
      guard width > 0 else { return 0.25 }
      let speed = max(35, width * CGFloat(settings.danmakuSpeed))
      let travel = width * 2 + 24
      let passTime = TimeInterval(travel / speed)
      let fontSize = CGFloat(settings.danmakuFontSize > 0 ? settings.danmakuFontSize : 17)
      let lineHeight = fontSize + 8
      let maxLines = settings.danmakuMaxLines > 0
        ? settings.danmakuMaxLines
        : max(1, Int(danmakuView.bounds.height / lineHeight))
      return passTime / Double(maxLines)
    }()
    // Spread the batch across ~one poll interval (burstSpacing) but never faster than the
    // lanes can absorb (laneCapacity). The upper cap is generous so small batches fill the
    // gap until the next poll instead of draining early and leaving a blank.
    let burstSpacing = lastChatPollInterval / Double(pendingChatMessages.count + 1)
    let spacing = min(max(max(burstSpacing, laneCapacity), 0.18), 2.5)
    let work = DispatchWorkItem { [weak self] in self?.dripNextChatMessage() }
    chatDripWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + spacing, execute: work)
  }

  func stopPlayback() {
    isStopped = true
    resolveTask?.cancel(); resolveTask = nil
    sponsorTask?.cancel(); sponsorTask = nil
    chatPollWorkItem?.cancel(); chatPollWorkItem = nil
    chatDripWorkItem?.cancel(); chatDripWorkItem = nil
    pendingChatMessages.removeAll()
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
    itemStatusObservation = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    fallbackWebView?.stopLoading()
    fallbackWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "youtubeAudio")
    fallbackWebView?.loadHTMLString("", baseURL: nil)
    fallbackWebView?.removeFromSuperview()
    fallbackWebView = nil
  }

  private func loadPlayer() {
    let raw = stream.channel.trimmingCharacters(in: .whitespacesAndNewlines)
    if let videoId = Self.videoID(from: raw) {
      installOfficialEmbed(videoId: videoId)
      startLiveChatPolling(videoId: videoId)
      return
    }
    resolveLiveVideoID(from: raw)
  }

  private func installOfficialEmbed(videoId: String) {
    requestNativePlayer(videoId: videoId)
  }

  private func requestNativePlayer(videoId: String, attempt: Int = 0) {
    guard !isStopped, player.currentItem == nil else { return }
    let clients = Self.nativePlayerClients()
    guard clients.indices.contains(attempt) else {
      noteExtractionFailure("Native player: manifest取得失敗")
      installAlternativeWebFallback(videoId: videoId)
      return
    }
    let client = clients[attempt]
    showStatus("YouTube HLS取得中\n\(client.label) \(attempt + 1)/\(clients.count)")
    guard let url = URL(string: "https://youtubei.googleapis.com/youtubei/v1/player") else {
      installAlternativeWebFallback(videoId: videoId)
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(client.headerClientName, forHTTPHeaderField: "X-YouTube-Client-Name")
    request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
    request.setValue("ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6", forHTTPHeaderField: "Accept-Language")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "context": client.context,
      "videoId": videoId,
      "contentCheckOk": true,
      "racyCheckOk": true,
      "playbackContext": [
        "contentPlaybackContext": [
          "html5Preference": "HTML5_PREF_WANTS"
        ]
      ]
    ])
    resolveTask?.cancel()
    resolveTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.resolveTask = nil
      if let error {
        DispatchQueue.main.async {
          self.noteExtractionFailure("\(client.label): \(error.localizedDescription)")
          self.requestNativePlayer(videoId: videoId, attempt: attempt + 1)
        }
        return
      }
      let parsed = Self.parseJSONObject(data)
      if let parsed, let stream = Self.extractPlayableStream(from: parsed) {
        DispatchQueue.main.async {
          guard !self.isStopped, self.player.currentItem == nil else { return }
          self.startPlayback(url: stream.url, videoId: videoId, isLive: stream.isLive)
        }
        return
      }
      DispatchQueue.main.async {
        let httpCode = (response as? HTTPURLResponse)?.statusCode
        self.noteExtractionFailure(Self.youtubeIErrorSummary(clientName: client.label, httpCode: httpCode, parsed: parsed, data: data))
        self.requestNativePlayer(videoId: videoId, attempt: attempt + 1)
      }
    }
    let task = resolveTask
    resolveTask?.resume()
    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak task] in
      guard let self,
            !self.isStopped,
            self.player.currentItem == nil,
            let task,
            self.resolveTask === task else { return }
      task.cancel()
      self.resolveTask = nil
      self.noteExtractionFailure("\(client.label): 12秒タイムアウト")
      self.requestNativePlayer(videoId: videoId, attempt: attempt + 1)
    }
  }

  private static func nativePlayerClients() -> [(label: String, headerClientName: String, version: String, userAgent: String, context: [String: Any])] {
    let iosVersion = "21.17.3"
    let iosUA = "com.google.ios.youtube/\(iosVersion) (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X; ja_JP)"
    let androidVersion = "20.19.35"
    let androidUA = "com.google.android.youtube/\(androidVersion) (Linux; U; Android 15) gzip"
    return [
      (
        label: "IOS",
        headerClientName: "5",
        version: iosVersion,
        userAgent: iosUA,
        context: [
          "client": [
            "clientName": "IOS",
            "clientVersion": iosVersion,
            "deviceMake": "Apple",
            "deviceModel": "iPhone16,2",
            "osName": "iOS",
            "osVersion": "17.5.1.21F90",
            "hl": "ja",
            "gl": "JP",
            "userAgent": iosUA
          ]
        ]
      ),
      (
        label: "ANDROID",
        headerClientName: "3",
        version: androidVersion,
        userAgent: androidUA,
        context: [
          "client": [
            "clientName": "ANDROID",
            "clientVersion": androidVersion,
            "androidSdkVersion": 35,
            "deviceMake": "Google",
            "deviceModel": "Pixel 9 Pro",
            "osName": "Android",
            "osVersion": "15",
            "hl": "ja",
            "gl": "JP",
            "userAgent": androidUA
          ]
        ]
      )
    ]
  }

  private static func extractPlayableStream(from parsed: [String: Any]) -> (url: URL, isLive: Bool)? {
    guard let sd = parsed["streamingData"] as? [String: Any] else { return nil }
    let details = parsed["videoDetails"] as? [String: Any]
    let isLive = (details?["isLive"] as? Bool) ?? (details?["isLiveContent"] as? Bool) ?? false
    if let hls = sd["hlsManifestUrl"] as? String, let url = URL(string: hls) {
      return (url, isLive)
    }
    let formats = ((sd["formats"] as? [[String: Any]]) ?? []) + ((sd["adaptiveFormats"] as? [[String: Any]]) ?? [])
    if let url = bestFormatURL(formats) {
      return (url, isLive)
    }
    return nil
  }

  private static func youtubeIErrorSummary(clientName: String, httpCode: Int?, parsed: [String: Any]?, data: Data?) -> String {
    var parts: [String] = [clientName]
    if let httpCode { parts.append("HTTP \(httpCode)") }
    if let status = parsed?["playabilityStatus"] as? [String: Any] {
      if let value = status["status"] as? String, !value.isEmpty { parts.append(value) }
      if let value = status["reason"] as? String, !value.isEmpty { parts.append(value) }
      if let value = status["subreason"] as? String, !value.isEmpty { parts.append(value) }
    }
    if let sd = parsed?["streamingData"] as? [String: Any] {
      let formats = ((sd["formats"] as? [Any])?.count ?? 0) + ((sd["adaptiveFormats"] as? [Any])?.count ?? 0)
      if formats == 0, sd["serverAbrStreamingUrl"] != nil {
        parts.append("SABRのみ")
      } else {
        parts.append("再生可能URLなし")
      }
    } else if parsed != nil {
      parts.append("streamingDataなし")
    } else if let data, !data.isEmpty {
      parts.append("JSON解析失敗")
    } else {
      parts.append("空レスポンス")
    }
    return parts.joined(separator: " / ")
  }

  private static func parseJSONObject(_ data: Data?) -> [String: Any]? {
    guard let data else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private func noteExtractionFailure(_ message: String) {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    extractionFailures.append(trimmed)
    if extractionFailures.count > 8 {
      extractionFailures.removeFirst(extractionFailures.count - 8)
    }
    showStatus("YouTube抽出中\n\(trimmed)")
  }

  // AVPlayer needs a playable stream by itself. YouTube adaptive video-only URLs
  // look tempting but fail/stall without the paired audio or SABR loader, so only
  // accept muxed/progressive formats here and let the caller try the next client.
  private static func bestFormatURL(_ formats: [[String: Any]]) -> URL? {
    let candidates: [(Int, Int, URL)] = formats.compactMap { fmt in
      guard let urlString = fmt["url"] as? String, let url = URL(string: urlString) else { return nil }
      let height = (fmt["height"] as? Int) ?? 0
      let bitrate = (fmt["bitrate"] as? Int) ?? 0
      let mime = (fmt["mimeType"] as? String) ?? ""
      let hasAudio = !mime.contains("video/") || mime.contains("mp4a") || (fmt["hasAudio"] as? Bool) == true
      guard mime.contains("video/"), hasAudio else { return nil }
      return (height, bitrate, url)
    }
    guard !candidates.isEmpty else { return nil }
    let sorted = candidates.sorted {
      if $0.0 == $1.0 { return $0.1 < $1.1 }
      return $0.0 < $1.0
    }
    return (sorted.last(where: { $0.0 <= 720 }) ?? sorted.last)?.2
  }

  private func startPlayback(url: URL, videoId: String, isLive: Bool) {
    guard !isStopped else { return }
    statusLabel.isHidden = true
    let asset = AVURLAsset(url: url, options: [
      "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": Self.userAgent],
      // Live HLS never needs a precise duration; skip that analysis to trim startup.
      AVURLAssetPreferPreciseDurationAndTimingKey: false
    ])
    let item = AVPlayerItem(asset: asset)
    item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
    if isLive {
      // LL-HLS配信なら効く(通常HLSはno-op)。ライブエッジ2秒を狙う(再詰め)。
      item.configuredTimeOffsetFromLive = CMTime(seconds: 1.5, preferredTimescale: 600)
      item.automaticallyPreservesTimeOffsetFromLive = true
    }
    itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      guard let self else { return }
      if item.status == .failed {
        DispatchQueue.main.async { self.installEmbedFallback(videoId: videoId) }
      } else if item.status == .readyToPlay {
        DispatchQueue.main.async { self.resumePlayback() }
      }
    }
    player.replaceCurrentItem(with: item)
    resumePlayback()
    [0.25, 0.9, 1.8].forEach { delay in
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak item] in
        guard let self,
              !self.isStopped,
              let item,
              self.player.currentItem === item,
              self.fallbackWebView == nil else { return }
        self.resumePlayback()
      }
    }
    // AVPlayer が .failed に遷移せず ready のまま無音で固まるケース (signatureCipher
    // 経由の壊れた URL でよく起きる) に備え、6秒以内に再生開始しなければ iframe へ。
    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self, weak item] in
      guard let self, !self.isStopped,
            self.fallbackWebView == nil,
            let item, self.player.currentItem === item,
            self.player.timeControlStatus != .playing else { return }
      self.noteExtractionFailure("6秒以内に再生されず: iframeへ")
      self.installEmbedFallback(videoId: videoId)
    }
    // SponsorBlock only applies to VOD (live has no segments).
    if !isLive {
      fetchSponsorBlock(videoId: videoId)
      installSponsorSkipObserver()
    }
  }

  // 2026年現在、YouTube は formats[*].url を出さず (signatureCipher のみ)、
  // hlsManifestUrl も SABR 強制で空のことが多い。Piped/Invidious 含む第三者
  // API も全滅していることを PC 検証済み。proxy 経路を回しても 10-15秒の
  // 黒画面を増やすだけなので、抽出失敗 = 直ちに iframe 描画に進む。
  private func installEmbedFallback(videoId: String) {
    guard !isStopped else { return }
    if player.currentItem != nil {
      itemStatusObservation = nil
      player.pause()
      player.replaceCurrentItem(with: nil)
    }
    noteExtractionFailure("抽出失敗: YouTube iframe fallback")
    installAlternativeWebFallback(videoId: videoId)
  }

  // YouTube official iframe player: YouTube 公式 iframe API (embedHTML) を
  // WKWebView に loadHTMLString する。watch ページ遷移や CSS chrome 隠しは
  // 廃止 (player 初期化を壊して thumbnail すら出ない問題があったため)。
  //
  // 動作仕様:
  //  - 自動再生は iOS WebKit ルールに合わせて muted 起動する。
  //  - ネイティブ音量操作で「音声をオン」ボタンを iframe 内に出し、WebView 内の
  //    user gesture で unmute する。ネイティブ側だけでは iOS が解除を拒否し得る。
  //  - YouTube セルの音声は focusAudio(on:) で 1 つに絞り、同時出力を避ける。
  //  - 広告は WebAdBlocker のコンテンツルール + embedHTML 内の iv_load_policy=3
  //    アノテーション無効化で抑制 (YouTube は完全には防げない)。
  //  - 他配信との衝突: YouTube は iframe だけを鳴らし、AVPlayer 抽出音声を
  //    起動経路から外して二重出力を防ぐ。
  //  - iframe が onError 102/150/152 (埋め込み禁止) を返した場合は、無理に
  //    watch ページに遷移せず error メッセージを overlay 表示する。
  private func installAlternativeWebFallback(videoId: String) {
    guard !isStopped, fallbackWebView == nil else { return }
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
    itemStatusObservation = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    showStatus("YouTube公式iframeで再生")
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    config.websiteDataStore = .default()
    config.userContentController.add(self, name: "youtubeAudio")
    WebAdBlocker.install(on: config)
    let web = WKWebView(frame: bounds, configuration: config)
    web.isOpaque = false
    web.backgroundColor = .black
    web.scrollView.backgroundColor = .black
    web.scrollView.isScrollEnabled = false
    web.scrollView.contentInsetAdjustmentBehavior = .never
    web.customUserAgent = Self.userAgent
    web.navigationDelegate = self
    web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    insertSubview(web, at: 0)
    fallbackWebView = web
    // ★重要★ baseURL は **自分の HTTPS ドメイン** にする。youtube.com や nil を指定
    // すると YouTube iframe API が embedder origin を不正と判定して error 152 を
    // 返す (8321d49 で確認済み)。tonton888115.github.io は GitHub Pages 経由で
    // SSL 有効、Origin として認められる。
    web.loadHTMLString(Self.embedHTML(videoId: videoId), baseURL: URL(string: "https://tonton888115.github.io/MultiView/"))
    statusLabel.isHidden = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      self?.resumePlayback()
    }
  }

  // MARK: - SponsorBlock (VOD)

  private func fetchSponsorBlock(videoId: String) {
    let digest = SHA256.hash(data: Data(videoId.utf8))
    let prefix = String(digest.map { String(format: "%02x", $0) }.joined().prefix(4))
    var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(prefix)")
    components?.queryItems = [
      URLQueryItem(name: "categories", value: "[\"sponsor\",\"selfpromo\",\"interaction\",\"intro\",\"outro\",\"preview\",\"music_offtopic\"]"),
      URLQueryItem(name: "actionTypes", value: "[\"skip\"]")
    ]
    guard let url = components?.url else { return }
    sponsorTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, !self.isStopped, let data,
            let bucket = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
      let entry = bucket.first { ($0["videoID"] as? String) == videoId }
      let segments = (entry?["segments"] as? [[String: Any]]) ?? []
      let parsed: [(start: Double, end: Double)] = segments.compactMap { seg in
        guard (seg["actionType"] as? String) == "skip",
              let arr = seg["segment"] as? [Any], arr.count == 2,
              let s = (arr[0] as? NSNumber)?.doubleValue,
              let e = (arr[1] as? NSNumber)?.doubleValue, e > s else { return nil }
        return (s, e)
      }.sorted { $0.start < $1.start }
      DispatchQueue.main.async {
        guard !self.isStopped else { return }
        self.sponsorSegments = parsed
      }
    }
    sponsorTask?.resume()
  }

  private func installSponsorSkipObserver() {
    guard timeObserver == nil else { return }
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.4, preferredTimescale: 600), queue: .main) { [weak self] time in
      guard let self, !self.isStopped, !self.sponsorSegments.isEmpty else { return }
      let t = time.seconds
      guard t.isFinite else { return }
      for seg in self.sponsorSegments where t >= seg.start && t < seg.end - 0.15 {
        self.player.seek(to: CMTime(seconds: seg.end + 0.1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        break
      }
    }
  }

  private func resolveLiveVideoID(from raw: String) {
    guard let url = Self.liveResolutionURL(from: raw) else {
      showStatus("YouTube動画IDまたはライブURLが不正です")
      return
    }
    showStatus("YouTubeライブURLを解決中")
    var request = URLRequest(url: url)
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
    request.setValue("ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6", forHTTPHeaderField: "Accept-Language")
    resolveTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      self.resolveTask = nil
      if let error {
        self.showStatus("YouTubeライブ解決失敗: \(error.localizedDescription)")
        return
      }
      if let finalURL = response?.url, let id = Self.videoID(from: finalURL.absoluteString) {
        DispatchQueue.main.async {
          self.installOfficialEmbed(videoId: id)
          self.startLiveChatPolling(videoId: id)
        }
        return
      }
      guard let data, let html = String(data: data, encoding: .utf8),
            let id = Self.extractVideoID(fromHTML: html) else {
        self.showStatus("YouTubeライブ動画IDを取得できません")
        return
      }
      DispatchQueue.main.async {
        self.installOfficialEmbed(videoId: id)
        self.startLiveChatPolling(videoId: id)
      }
    }
    resolveTask?.resume()
  }

  private func showStatus(_ text: String) {
    DispatchQueue.main.async {
      self.statusLabel.text = text
      self.statusLabel.isHidden = false
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    guard !isStopped else { return }
    showStatus("YouTube読み込み失敗: \(error.localizedDescription)")
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    guard !isStopped else { return }
    showStatus("YouTube読み込み失敗: \(error.localizedDescription)")
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard !isStopped else { return }
    if message.name == "youtubeAudio" {
      iframeAudioEnabled = true
      Self.focusAudio(on: self)
      fallbackWebView?.evaluateJavaScript("window.mvSetVolume && window.mvSetVolume(\(iframeEffectiveVolume()));")
      return
    }
  }

  // YouTube official embed: YouTube 公式 iframe API。当時 (8321d49) 動いてた構造を踏襲。
  //
  // iOS WebKit の autoplay policy: video.muted=true (初期) でない限り autoplay は
  // 拒否される。だから playerVars に **mute:1** が必須。mute を抜くと iframe は
  // サムネ + 再生ボタンで待機状態 (まさにユーザ報告のスピナー)。
  //
  // 構造:
  //  - playerVars: autoplay:1 + **mute:1** で初期 muted の自動再生を許可
  //  - onReady: playVideo() を呼んで再生開始
  //  - onStateChange: UNSTARTED/CUED に戻ったら playVideo() を再試行
  //    (広告挿入後や autoplay 拒否時に CUED で固まるケースの保険)
  //  - apply(): 音量制御。AUDIO=true なら unMute+setVolume、false なら mute
  //  - mvVolume bridge は Swift 側 setPlaybackVolume(0-1) を受けて 0-100 に変換
  //  - onError は err overlay に日本語メッセージ表示 (watch ページ遷移はしない)
  //  - SponsorBlock スキッパ内蔵 (VOD 用、live では no-op)
  private static func embedHTML(videoId: String) -> String {
    let sbCategories = "%5B%22sponsor%22%2C%22selfpromo%22%2C%22interaction%22%2C%22intro%22%2C%22outro%22%2C%22preview%22%2C%22music_offtopic%22%5D"
    return """
    <!doctype html>
    <html>
    <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <style>html,body,#player{margin:0;width:100%;height:100%;background:#000;overflow:hidden}iframe{position:absolute;inset:0;width:100%;height:100%;border:0;background:#000}#err{position:absolute;inset:0;display:none;align-items:center;justify-content:center;color:#fff;font-family:-apple-system;text-align:center;padding:18px;font-size:13px;line-height:1.5}#err a{color:#9ecbff}#audio{position:fixed;left:50%;bottom:16px;transform:translateX(-50%);z-index:20;display:none;align-items:center;justify-content:center;padding:10px 16px;border-radius:18px;border:1px solid rgba(255,255,255,.34);background:rgba(18,24,32,.88);color:#fff;font:700 13px -apple-system,BlinkMacSystemFont,sans-serif}</style></head>
    <body>
    <div id="player"></div>
    <div id="err"></div>
    <button id="audio">音声をオン</button>
    <script src="https://www.youtube.com/iframe_api"></script>
    <script>
      var player=null, READY=false, AUDIO=false, VOL=0, sb=[], hasPlayedOnce=false, userGesture=false;
      // iOS autoplay policy: muted の playVideo() は許可されるが、
      // user gesture (touchstart) なしの unMute() は autoplay 違反として
      // 直後に video を pause させる。userGesture フラグで gesture 前は
      // 必ず mute を維持して video の継続再生を保証する。
      function apply(){
        if(!player||!READY)return;
        try{
          player.playVideo();
          if(AUDIO && userGesture){player.unMute();player.setVolume(VOL);}
          else{player.mute();}
        }catch(e){}
        updateAudioButton();
      }
      function updateAudioButton(){
        var b=document.getElementById('audio');
        if(!b)return;
        b.style.display=(AUDIO && !userGesture)?'flex':'none';
      }
      // user gesture を検出したら即 unmute トライ
      function onGesture(){
        if(userGesture) return;
        userGesture = true;
        try{window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.youtubeAudio.postMessage('focus');}catch(e){}
        try{ if(player && READY && AUDIO){player.unMute();player.setVolume(VOL);} }catch(e){}
        updateAudioButton();
      }
      document.addEventListener('touchstart', onGesture, {capture:true, passive:true});
      document.addEventListener('click', onGesture, {capture:true});
      function loadSB(){
        try{
          fetch('https://sponsor.ajay.app/api/skipSegments?videoID=\(videoId)&categories=\(sbCategories)&actionTypes=%5B%22skip%22%5D')
            .then(function(r){return r.ok?r.json():[];})
            .then(function(list){sb=(list||[]).filter(function(s){return s.actionType==='skip'&&s.segment;}).map(function(s){return {s:s.segment[0],e:s.segment[1]};});})
            .catch(function(){});
        }catch(e){}
      }
      function sbTick(){
        if(!player||!READY||!sb.length)return;
        try{
          var t=player.getCurrentTime();
          for(var i=0;i<sb.length;i++){if(t>=sb[i].s&&t<sb[i].e-0.15){player.seekTo(sb[i].e+0.1,true);break;}}
        }catch(e){}
      }
      function describeError(code){
        switch(code){
          case 2: return '動画ID不正';
          case 5: return 'HTML5プレイヤー初期化失敗';
          case 100: return '動画が見つかりません/非公開';
          case 101:
          case 150:
          case 152: return '配信者が埋め込み再生を禁止しています';
          case 153: return 'HTML5再生制限';
          case 157: return 'ネットワーク経路エラー';
          default: return 'YouTube iframe エラー: '+code;
        }
      }
      function showError(code){
        var el=document.getElementById('err');
        el.innerHTML=describeError(code)+'<br><br><a href="https://www.youtube.com/watch?v=\(videoId)" target="_blank">YouTube アプリで開く</a>';
        el.style.display='flex';
        document.getElementById('player').style.display='none';
      }
      window.onYouTubeIframeAPIReady=function(){
        player=new YT.Player('player',{
          width:'100%',height:'100%',videoId:'\(videoId)',
          host:'https://www.youtube.com',
          playerVars:{autoplay:1,mute:1,playsinline:1,controls:1,rel:0,fs:1,iv_load_policy:3,origin:'https://tonton888115.github.io'},
          events:{
            onReady:function(){READY=true;apply();loadSB();},
            onStateChange:function(e){
              if(e.data===YT.PlayerState.PLAYING){hasPlayedOnce=true;return;}
              // 初回再生 (本編) に到達する前の UNSTARTED/CUED/PAUSED で固まる
              // (典型: 広告→本編 遷移で iframe が PAUSED に張り付く) ケースを
              // aggressive に retry。一度 PLAYING に入ったら以降は user pause
              // も尊重するため触らない。
              if(!hasPlayedOnce && (
                e.data===YT.PlayerState.UNSTARTED||
                e.data===YT.PlayerState.CUED||
                e.data===YT.PlayerState.PAUSED
              )){
                setTimeout(function(){try{e.target.playVideo();}catch(x){}},250);
              }
            },
            onError:function(e){showError(e.data);}
          }
        });
      };
      window.mvPlay=function(){apply();};
      window.mvPause=function(){try{player&&player.pauseVideo();}catch(e){}};
      window.mvSetVolume=function(v){
        var n=Math.max(0,Math.min(1,+v||0));
        VOL=Math.round(n*100); AUDIO=VOL>0;
        apply();
      };
      setInterval(sbTick, 400);
    </script>
    </body>
    </html>
    """
  }

  static func videoID(from raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil {
      return trimmed
    }
    let normalized: String
    if trimmed.hasPrefix("youtu.be/") || trimmed.hasPrefix("youtube.com/") || trimmed.hasPrefix("www.youtube.com/") || trimmed.hasPrefix("m.youtube.com/") {
      normalized = "https://\(trimmed)"
    } else {
      normalized = trimmed.contains("://") ? trimmed : "https://www.youtube.com/\(trimmed)"
    }
    guard let url = URL(string: normalized) else {
      return nil
    }
    let host = url.host?.replacingOccurrences(of: "www.", with: "").lowercased() ?? ""
    let parts = url.path.split(separator: "/").map(String.init)
    if host == "youtu.be", let first = parts.first, first.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil {
      return first
    }
    if host.contains("youtube.com"),
       let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
       v.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil {
      return v
    }
    if host.contains("youtube.com"),
       ["live", "embed", "shorts"].contains(parts.first ?? ""),
       parts.count > 1,
       parts[1].range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil {
      return parts[1]
    }
    return nil
  }

  static func liveResolutionURL(from raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("youtube.com/") || trimmed.hasPrefix("www.youtube.com/") || trimmed.hasPrefix("m.youtube.com/") {
      return liveResolutionURL(from: "https://\(trimmed)")
    }
    if let url = URL(string: trimmed), let host = url.host?.lowercased(), host.contains("youtube.com") {
      if url.path.hasSuffix("/live") {
        return url
      }
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      var path = components?.path ?? url.path
      if !path.hasSuffix("/") { path += "/" }
      path += "live"
      components?.path = path
      components?.queryItems = nil
      return components?.url
    }
    if trimmed.hasPrefix("@") {
      return URL(string: "https://www.youtube.com/\(trimmed)/live")
    }
    if trimmed.hasPrefix("channel/") || trimmed.hasPrefix("c/") || trimmed.hasPrefix("user/") {
      return URL(string: "https://www.youtube.com/\(trimmed)/live")
    }
    if trimmed.hasPrefix("UC") {
      return URL(string: "https://www.youtube.com/channel/\(trimmed)/live")
    }
    let handle = trimmed.replacingOccurrences(of: "^@+", with: "", options: .regularExpression)
      .components(separatedBy: CharacterSet(charactersIn: "/?# ")).first ?? trimmed
    return URL(string: "https://www.youtube.com/@\(handle)/live")
  }

  static func extractVideoID(fromHTML html: String) -> String? {
    let patterns = [
      #"<link rel=\"canonical\" href=\"https://www\.youtube\.com/watch\?v=([A-Za-z0-9_-]{11})\""#,
      #"watch\?v=([A-Za-z0-9_-]{11})"#,
      #""videoId":"([A-Za-z0-9_-]{11})""#
    ]
    for pattern in patterns {
      if let match = html.range(of: pattern, options: .regularExpression) {
        let segment = String(html[match])
        if let idRange = segment.range(of: #"[A-Za-z0-9_-]{11}"#, options: .regularExpression) {
          return String(segment[idRange])
        }
      }
    }
    return nil
  }

  static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
}
