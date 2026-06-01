import UIKit
import WebKit
import AVFoundation
import AmazonIVSPlayer

// Native Twitch playback: fetch a PlaybackAccessToken over GraphQL, build the
// usher.ttvnw.net HLS master playlist, and try IVSPlayer first. If IVS cannot
// handle Twitch's HLS shape, fall back to the proven AVPlayer path, then web.
// Anonymous IRC supplies danmaku comments.
final class TwitchNativePlayerView: UIView, PlaybackResumable, PlaybackStoppable, AudioControllable, CommentPostable, CommentEchoDisplay, IVSPlayer.Delegate, IVSPlaybackHost {
  private let stream: StreamItem
  let settings: AppSettings
  private let player = AVPlayer()
  let playerLayer = AVPlayerLayer()
  var ivsPlayer: IVSPlayer?
  var ivsPlayerLayer: IVSPlayerLayer?
  private let danmakuView = UIView()
  private let statusLabel = UILabel()
  var playbackVolume: Float
  private var tokenTask: URLSessionDataTask?
  private var chatSocket: URLSessionWebSocketTask?
  private var chatChannel: String?
  private lazy var stallWatchdog = StallWatchdog(player: player) { [weak self] in
    self?.recoverFromStall()
  }
  private var itemStatusObservation: NSKeyValueObservation?
  private var itemFailedObserver: NSObjectProtocol?
  private var liveCatchUpTimer: Timer?
  var ivsBufferingRecoveryWork: DispatchWorkItem?
  private var fallbackWebView: PlayerWebView?
  private var currentHLSURL: URL?
  private var playbackGeneration = 0
  private let nativeRetry = NativeRetryLimiter(maxAttempts: 2)
  private let ivsRetry = NativeRetryLimiter(maxAttempts: 1)
  var usingIvsPlayback = false
  private var forceLegacyPlayback = false
  private var isLoading = false
  private var isStopped = false
  private var laneCursor = 0

  private static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
  private static let accessTokenHash = "0828119ded1c13477966434e15800ff57ddacf13ba1911c129dc2200705b0712"
  private static let userAgent = BrowserUserAgent.mobileSafari
  private static var useIvsPlayer: Bool {
    !UserDefaults.standard.bool(forKey: "playback.twitch.ivs.disabled")
  }

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
    layoutIvsLayer()
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
    if resumeIvsPlaybackIfActive() { return }
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
    pauseIvsPlayback()
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
    teardownIvsPlayback(removeLayer: true)
    itemStatusObservation = nil
    if let itemFailedObserver {
      NotificationCenter.default.removeObserver(itemFailedObserver)
      self.itemFailedObserver = nil
    }
  }

  func setPlaybackVolume(_ volume: Float) {
    playbackVolume = min(1, max(0, volume))
    player.volume = settings.playAudio ? playbackVolume : 0
    applyIvsAudio()
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
      self.currentHLSURL = hlsURL
      if Self.useIvsPlayer, !self.forceLegacyPlayback {
        self.playWithIvs(hlsURL: hlsURL, requestGeneration: requestGeneration)
      } else {
        self.playWithAVPlayer(hlsURL: hlsURL, requestGeneration: requestGeneration)
      }
    }
  }

  private func playWithIvs(hlsURL: URL, requestGeneration: Int) {
    DispatchQueue.main.async {
      self.isLoading = false
      guard !self.isStopped, requestGeneration == self.playbackGeneration,
            self.fallbackWebView == nil else { return }
      self.statusLabel.isHidden = true
      self.playbackGeneration += 1
      let generation = self.playbackGeneration
      self.teardownAVPlayerPlayback()

      let ivs = IVSPlayer()
      ivs.delegate = self
      ivs.autoQualityMode = true
      ivs.setOrigin(URL(string: "https://player.twitch.tv"))
      ivs.setLiveLowLatencyEnabled(true)
      ivs.setRebufferToLive(true)
      ivs.setNetworkRecoveryMode(.resume)
      ivs.setInitialBufferDuration(CMTime(seconds: 1.2, preferredTimescale: 600))
      let peakBitRate = NetworkQuality.shared.effectivePeakBitRate(settings: self.settings)
      if peakBitRate > 0 {
        ivs.setAutoMaxBitrate(Int(peakBitRate))
      }

      self.attachIvsPlayer(ivs)

      ivs.load(hlsURL)
      ivs.play()
      self.scheduleIvsBufferingRecovery(generation: generation)
    }
  }

  private func playWithAVPlayer(hlsURL: URL, requestGeneration: Int) {
    DispatchQueue.main.async {
      guard !self.isStopped, requestGeneration == self.playbackGeneration,
            self.fallbackWebView == nil else { return }
      self.statusLabel.isHidden = true
      self.playbackGeneration += 1
      let generation = self.playbackGeneration
      self.teardownIvsPlayback(removeLayer: false)
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
    teardownIvsPlayback(removeLayer: false)
    teardownAVPlayerPlayback()
  }

  private func teardownAVPlayerPlayback() {
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
          self.tokenTask?.cancel()
          self.tokenTask = nil
        },
        resetLoading: { self.isLoading = false },
        showRetry: { attempt in
          self.showStatus("Twitch再接続中(\(attempt)/\(self.nativeRetry.maxAttempts))")
        },
        reload: { self.loadNativeStream() },
        fallback: { self.installFallback(reason) }
      )
    }
  }

  private func handleIvsFailure(_ reason: String, generation: Int) {
    DispatchQueue.main.async {
      guard !self.isStopped, self.fallbackWebView == nil,
            self.usingIvsPlayback, generation == self.playbackGeneration else { return }
      if let attempt = self.ivsRetry.nextAttempt() {
        self.teardownIvsPlayback(removeLayer: false)
        self.showStatus("Twitch SDK再接続中(\(attempt)/\(self.ivsRetry.maxAttempts))")
        if let hlsURL = self.currentHLSURL {
          self.playWithIvs(hlsURL: hlsURL, requestGeneration: generation)
        } else {
          self.retryNativeLoadOrFallback(reason, generation: generation)
        }
        return
      }
      if let hlsURL = self.currentHLSURL {
        self.forceLegacyPlayback = true
        self.teardownIvsPlayback(removeLayer: false)
        self.showStatus("Twitch SDKが未対応のため旧ネイティブ再生へ切替中")
        self.playWithAVPlayer(hlsURL: hlsURL, requestGeneration: generation)
        return
      }
      self.retryNativeLoadOrFallback(reason, generation: generation)
    }
  }

  private func scheduleIvsBufferingRecovery(generation: Int) {
    ivsBufferingRecoveryWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.isStopped, self.usingIvsPlayback,
            generation == self.playbackGeneration,
            self.ivsPlayer?.state == .buffering else { return }
      self.handleIvsFailure("Twitch SDKのバッファリングが続いています", generation: generation)
    }
    ivsBufferingRecoveryWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 14, execute: work)
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

  func player(_ player: IVSPlayer, didChangeState state: IVSPlayer.State) {
    guard ownsIvsPlayer(player), !isStopped else { return }
    let generation = playbackGeneration
    switch state {
    case .ready:
      nativeRetry.reset()
      ivsRetry.reset()
      applyIvsAudio()
      statusLabel.isHidden = true
      player.play()
    case .buffering:
      scheduleIvsBufferingRecovery(generation: generation)
    case .playing:
      ivsBufferingRecoveryWork?.cancel()
      ivsBufferingRecoveryWork = nil
      statusLabel.isHidden = true
    case .ended:
      handleIvsFailure("Twitch SDK再生が終了しました", generation: generation)
    case .idle:
      break
    @unknown default:
      break
    }
  }

  func player(_ player: IVSPlayer, didFailWithError error: Error) {
    guard ownsIvsPlayer(player) else { return }
    handleIvsFailure(error.localizedDescription, generation: playbackGeneration)
  }

  func playerWillRebuffer(_ player: IVSPlayer) {
    guard ownsIvsPlayer(player), !isStopped else { return }
    scheduleIvsBufferingRecovery(generation: playbackGeneration)
  }

  func playerNetworkDidBecomeUnavailable(_ player: IVSPlayer) {
    guard ownsIvsPlayer(player), !isStopped else { return }
    showStatus("Twitch SDKネットワーク復旧待ち")
    scheduleIvsBufferingRecovery(generation: playbackGeneration)
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
