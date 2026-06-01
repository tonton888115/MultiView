import UIKit
import WebKit
import AVFoundation
import AmazonIVSPlayer

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

final class KickNativePlayerView: UIView, PlaybackResumable, PlaybackStoppable, AudioControllable, CommentPostable, CommentEchoDisplay, IVSPlayer.Delegate, IVSPlaybackHost {
  private let stream: StreamItem
  let settings: AppSettings
  private let player = AVPlayer()
  let playerLayer = AVPlayerLayer()
  var ivsPlayer: IVSPlayer?
  var ivsPlayerLayer: IVSPlayerLayer?
  private let danmakuView = UIView()
  private let statusLabel = UILabel()
  var playbackVolume: Float
  private var channelTask: URLSessionDataTask?
  private var socketTask: URLSessionWebSocketTask?
  private var itemStatusObservation: NSKeyValueObservation?
  private var itemFailedObserver: NSObjectProtocol?
  private var fallbackWebView: PlayerWebView?
  private var chatroomID: String?
  private var kickChannelID: String?
  private var liveCatchUpTimer: Timer?
  private var lowLatencyLoader: KickLowLatencyLoader?
  var ivsBufferingRecoveryWork: DispatchWorkItem?
  var usingIvsPlayback = false
  private var forceLegacyPlayback = false
  private let ivsRetry = NativeRetryLimiter(maxAttempts: 2)
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
    pauseIvsPlayback()
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
    ivsRetry.reset()
    ivsBufferingRecoveryWork?.cancel()
    ivsBufferingRecoveryWork = nil
    teardownIvsPlayback(removeLayer: true)
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
    applyIvsAudio()
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
        self.retryKickLoadOrFallback("Kick HLS取得失敗: \(error.localizedDescription)")
        return
      }
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        if http.statusCode == 401 || http.statusCode == 403 {
          self.installFallback("Kick HLS取得失敗: HTTP \(http.statusCode)")
        } else {
          self.retryKickLoadOrFallback("Kick HLS取得失敗: HTTP \(http.statusCode)")
        }
        return
      }
      guard let data else {
        self.retryKickLoadOrFallback("Kick HLS URLを取得できません")
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
        self.retryKickLoadOrFallback("Kick HLS URLを取得できません")
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
    if Self.useIvsPlayer, !forceLegacyPlayback {
      playWithIvs(hlsURL: hlsURL)
    } else {
      playWithAVPlayer(hlsURL: hlsURL, lowLatency: lowLatency)
    }
  }

  private func playWithIvs(hlsURL: URL) {
    DispatchQueue.main.async {
      guard !self.isStopped, self.fallbackWebView == nil else { return }
      self.statusLabel.isHidden = true
      self.currentHLSURL = hlsURL
      self.playbackGeneration += 1
      let generation = self.playbackGeneration
      self.teardownAVPlayerPlayback()

      let ivs = IVSPlayer()
      ivs.delegate = self
      ivs.autoQualityMode = true
      ivs.setOrigin(URL(string: "https://kick.com"))
      ivs.setLiveLowLatencyEnabled(!self.stableMode)
      ivs.setRebufferToLive(!self.stableMode)
      ivs.setNetworkRecoveryMode(.resume)
      ivs.setInitialBufferDuration(CMTime(seconds: self.stableMode ? 3.0 : 1.2, preferredTimescale: 600))
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

  private func playWithAVPlayer(hlsURL: URL, lowLatency: Bool = true) {
    DispatchQueue.main.async {
      guard !self.isStopped else { return }
      self.teardownIvsPlayback(removeLayer: false)
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
    teardownIvsPlayback(removeLayer: false)
    teardownAVPlayerPlayback()
  }

  private func teardownAVPlayerPlayback() {
    lowLatencyLoader = nil
    NativeAVPlaybackCleanup.run(
      player: player,
      playerLayer: playerLayer,
      liveCatchUpTimer: &liveCatchUpTimer,
      stallWatchdog: stallWatchdog,
      itemStatusObservation: &itemStatusObservation,
      itemFailedObserver: &itemFailedObserver
    )
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
      NativeFallbackRetry.retryOrFallback(
        isStopped: self.isStopped,
        fallbackActive: self.fallbackWebView != nil,
        generation: generation,
        currentGeneration: self.playbackGeneration,
        limiter: self.nativeRetry,
        teardown: { self.teardownPlayback() },
        cancelRequest: {
          self.channelTask?.cancel()
          self.channelTask = nil
        },
        resetLoading: { self.isLoading = false },
        showRetry: { attempt in
          self.showStatus("Kick再接続中(\(attempt)/\(self.nativeRetry.maxAttempts))")
        },
        reload: { self.loadNativeStream() },
        fallback: { self.installFallback(reason) }
      )
    }
  }

  private func retryKickLoadOrFallback(_ reason: String) {
    DispatchQueue.main.async {
      NativeFallbackRetry.retryOrFallback(
        isStopped: self.isStopped,
        fallbackActive: self.fallbackWebView != nil,
        currentGeneration: self.playbackGeneration,
        limiter: self.nativeRetry,
        teardown: { self.teardownPlayback() },
        cancelRequest: {
          self.channelTask?.cancel()
          self.channelTask = nil
        },
        resetLoading: { self.isLoading = false },
        showRetry: { attempt in
          self.showStatus("Kick再接続中(\(attempt)/\(self.nativeRetry.maxAttempts))")
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
        self.channelTask?.cancel()
        self.channelTask = nil
        self.isLoading = false
        self.showStatus("Kick SDK再接続中(\(attempt)/\(self.ivsRetry.maxAttempts))")
        self.loadNativeStream()
        return
      }
      if let hlsURL = self.currentHLSURL {
        self.forceLegacyPlayback = true
        self.teardownIvsPlayback(removeLayer: false)
        self.showStatus("Kick SDKが不安定なため旧ネイティブ再生へ切替中")
        self.playWithAVPlayer(hlsURL: hlsURL, lowLatency: false)
        return
      }
      self.installFallback(reason)
    }
  }

  private func scheduleIvsBufferingRecovery(generation: Int) {
    ivsBufferingRecoveryWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.isStopped, self.usingIvsPlayback,
            generation == self.playbackGeneration,
            self.ivsPlayer?.state == .buffering else { return }
      self.handleIvsFailure("Kick SDKのバッファリングが続いています", generation: generation)
    }
    ivsBufferingRecoveryWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 18, execute: work)
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
      self.teardownPlayback()
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

  func player(_ player: IVSPlayer, didChangeState state: IVSPlayer.State) {
    guard ownsIvsPlayer(player), !isStopped else { return }
    let generation = playbackGeneration
    switch state {
    case .ready:
      nativeRetry.reset()
      ivsRetry.reset()
      scheduleStableModeReset()
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
      handleIvsFailure("Kick SDK再生が終了しました", generation: generation)
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
    showStatus("Kick SDKネットワーク復旧待ち")
    scheduleIvsBufferingRecovery(generation: playbackGeneration)
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
  private static var useIvsPlayer: Bool {
    !UserDefaults.standard.bool(forKey: "playback.kick.ivs.disabled")
  }
}
