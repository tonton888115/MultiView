import UIKit
import WebKit
import AVFoundation
import CryptoKit

// Per-cell YouTube playback first tries native HLS via InnerTube, then falls back
// to the official iframe.
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
      applyIframeVolume(to: fallbackWebView)
      fallbackWebView.evaluateJavaScript("window.mvPlay && window.mvPlay();")
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
    applyIframeVolume()
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
    applyIframeVolume()
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
    fallbackWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "youtubeAudio")
    fallbackWebView?.stopLoadingAndRemove()
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

  // YouTube often returns SABR-only/no direct URL. Extra extractor chains were
  // removed because they only added black-screen delay; fail fast to iframe.
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
  //  - iframe fallback の音声は focusAudio(on:) で 1 つに絞り、同時出力を避ける。
  //  - 広告は WebAdBlocker のコンテンツルール + embedHTML 内の iv_load_policy=3
  //    アノテーション無効化で抑制 (YouTube は完全には防げない)。
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
      applyIframeVolume()
      return
    }
  }

  private func applyIframeVolume(to webView: WKWebView? = nil) {
    let effective = iframeEffectiveVolume()
    (webView ?? fallbackWebView)?.evaluateJavaScript("window.mvSetVolume && window.mvSetVolume(\(effective));")
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
