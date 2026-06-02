import UIKit
import WebKit
import AVFoundation

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

  // 共通の lane-occupancy レンダラへ統一。旧独自実装は round-robin(laneCursor%maxLines)で
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

  static let userAgent = BrowserUserAgent.mobileSafari
}
