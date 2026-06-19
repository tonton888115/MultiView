import UIKit
import WebKit
import AVFoundation

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

    // TwitCasting's media playlists are not consistently low-latency enough to
    // chase the live edge aggressively. Let AVPlayer keep a small safety buffer
    // so the picture stays smooth on weaker or multi-stream connections.
    player.automaticallyWaitsToMinimizeStalling = true
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
      fallbackWebView.playAllMedia()
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
    fallbackWebView?.pauseAllMedia()
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
    fallbackWebView?.stopLoadingAndRemove()
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
      // エコノミー時は 360p 以下へ解像度も制限して通信量を節約する。
      item.preferredMaximumResolution = NetworkQuality.shared.effectiveMaximumResolution(settings: self.settings)
      item.preferredForwardBufferDuration = 4
      // TwitCasting prioritizes smoothness over Kick/Twitch-style live-edge
      // chasing. 1.5s caused visible judder on ordinary HLS streams.
      item.configuredTimeOffsetFromLive = CMTime(seconds: 5, preferredTimescale: 1)
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
    liveCatchUpTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
      self?.catchUpToLiveEdge()
    }
  }

  private func catchUpToLiveEdge() {
    LiveEdgeCatchUp.seekIfNeeded(
      player: player,
      isStopped: isStopped,
      fallbackActive: fallbackWebView != nil,
      behindThreshold: 18,
      targetOffset: 8,
      toleranceBefore: 2
    )
  }

  private func teardownPlayback() {
    playbackGeneration += 1
    NativeAVPlaybackCleanup.run(
      player: player,
      playerLayer: playerLayer,
      liveCatchUpTimer: &liveCatchUpTimer,
      stallWatchdog: stallWatchdog,
      itemStatusObservation: &itemStatusObservation,
      itemFailedObserver: &itemFailedObserver
    )
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
      NativeFallbackRetry.retryOrFallback(
        isStopped: self.isStopped,
        fallbackActive: self.fallbackWebView != nil,
        generation: generation,
        currentGeneration: self.playbackGeneration,
        limiter: self.nativeRetry,
        teardown: { self.teardownPlayback() },
        cancelRequest: {
          self.streamTask?.cancel()
          self.streamTask = nil
        },
        resetLoading: { self.isLoading = false },
        showRetry: { attempt in
          self.showStatus("ツイキャス再接続中(\(attempt)/\(self.nativeRetry.maxAttempts))")
        },
        reload: { self.loadNativeStream() },
        fallback: { self.installEmbedFallback(reason) }
      )
    }
  }

  private func applyFallbackVolume() {
    guard let fallbackWebView else { return }
    let effectiveVolume = settings.playAudio ? playbackVolume : 0
    fallbackWebView.setAllMediaVolume(effectiveVolume, muted: effectiveVolume <= 0)
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

  private static let userAgent = BrowserUserAgent.mobileSafari
}
