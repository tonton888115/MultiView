import UIKit
import WebKit
import AVFoundation
import Network

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    configureAudioSession()
    installPlaybackObservers()
    application.beginReceivingRemoteControlEvents()
    window = UIWindow(frame: UIScreen.main.bounds)
    window?.rootViewController = MainTabController()
    window?.makeKeyAndVisible()
    return true
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    configureAudioSession()
    resumePlaybackSoon()
  }

  func applicationWillResignActive(_ application: UIApplication) {
    configureAudioSession()
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    configureAudioSession()
  }

  func applicationWillEnterForeground(_ application: UIApplication) {
    configureAudioSession()
    resumePlaybackSoon()
  }

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default, options: [])
    do {
      try session.setActive(true, options: [])
    } catch {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        try? session.setActive(true, options: [])
      }
    }
  }

  private func installPlaybackObservers() {
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(playbackSignalReceived(_:)), name: AVAudioSession.interruptionNotification, object: nil)
    center.addObserver(self, selector: #selector(playbackSignalReceived(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
  }

  @objc private func playbackSignalReceived(_ notification: Notification) {
    if notification.name == AVAudioSession.interruptionNotification {
      guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw),
            type == .ended else { return }
      if let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
        guard options.contains(.shouldResume) else { return }
      }
    }
    configureAudioSession()
    resumePlaybackSoon()
  }

  private func resumePlaybackSoon() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      PlaybackCoordinator.shared.resumeAll()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
      PlaybackCoordinator.shared.resumeAll()
    }
  }
}

protocol PlaybackResumable: AnyObject {
  func resumePlayback()
}

protocol PlaybackStoppable: AnyObject {
  func stopPlayback()
}

protocol AudioControllable: AnyObject {
  func setPlaybackVolume(_ volume: Float)
}

final class AutoHidingControls: NSObject {
  private weak var host: UIView?
  private let controls: [UIView]
  private var hideWorkItem: DispatchWorkItem?

  init(host: UIView, controls: [UIView]) {
    self.host = host
    self.controls = controls
    super.init()
    let tap = UITapGestureRecognizer(target: self, action: #selector(showTemporarily))
    tap.cancelsTouchesInView = false
    host.addGestureRecognizer(tap)
    showTemporarily()
  }

  @objc func showTemporarily() {
    hideWorkItem?.cancel()
    UIView.animate(withDuration: 0.16) {
      self.controls.forEach { $0.alpha = 1 }
    }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      UIView.animate(withDuration: 0.25) {
        self.controls.forEach { $0.alpha = 0 }
      }
    }
    hideWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
  }
}

final class PlaybackCoordinator {
  static let shared = PlaybackCoordinator()
  private let views = NSHashTable<AnyObject>.weakObjects()

  func register(_ view: PlaybackResumable) {
    views.add(view as AnyObject)
  }

  func resumeAll() {
    for object in views.allObjects {
      (object as? PlaybackResumable)?.resumePlayback()
    }
  }
}

enum StreamPlatform: String, CaseIterable, Codable {
  case kick
  case twitch
  case youtube
  case niconico
  case twitcasting

  var label: String {
    switch self {
    case .kick: return "Kick"
    case .twitch: return "Twitch"
    case .youtube: return "YouTube"
    case .niconico: return "ニコ生"
    case .twitcasting: return "ツイキャス"
    }
  }

  var tint: UIColor {
    switch self {
    case .kick: return UIColor(red: 0.32, green: 0.99, blue: 0.09, alpha: 1)
    case .twitch: return UIColor(red: 0.57, green: 0.27, blue: 1, alpha: 1)
    case .youtube: return UIColor(red: 1, green: 0, blue: 0, alpha: 1)
    case .niconico: return UIColor(red: 1, green: 0.49, blue: 0, alpha: 1)
    case .twitcasting: return UIColor(red: 0, green: 0.63, blue: 0.91, alpha: 1)
    }
  }

  var hint: String {
    switch self {
    case .youtube: return "動画ID"
    case .niconico: return "番組ID"
    case .twitcasting: return "ユーザーID"
    default: return "チャンネル名"
    }
  }

  var usesIndividualPlayer: Bool {
    switch self {
    case .kick, .niconico, .twitch, .twitcasting:
      return true
    case .youtube:
      return false
    }
  }
}

struct StreamItem: Codable, Equatable {
  let id: String
  let platform: StreamPlatform
  let channel: String
}

enum LayoutMode: String, Codable {
  case stacked
  case grid
}

enum PlaybackQuality: String, Codable {
  case high
  case economy

  var label: String {
    switch self {
    case .high: return "高画質"
    case .economy: return "エコノミー"
    }
  }

  var preferredPeakBitRate: Double {
    switch self {
    case .high: return 0
    case .economy: return 900_000
    }
  }

  var niconicoQuality: String {
    switch self {
    case .high: return "abr"
    case .economy: return "low"
    }
  }
}

struct AppSettings: Codable {
  var showChat = true
  var proxyUrl = ""
  var playAudio = true
  var layoutMode: LayoutMode = .stacked
  var wifiQuality: PlaybackQuality = .high
  var mobileQuality: PlaybackQuality = .economy
  var danmakuFontSize = 20.0
  var danmakuSpeed = 0.13
  var danmakuOpacity = 0.9
  var danmakuMaxLines = 0
  var danmakuMaxLength = 0
  var platformOrder = StreamPlatform.allCases

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    showChat = try container.decodeIfPresent(Bool.self, forKey: .showChat) ?? true
    proxyUrl = try container.decodeIfPresent(String.self, forKey: .proxyUrl) ?? ""
    playAudio = try container.decodeIfPresent(Bool.self, forKey: .playAudio) ?? true
    layoutMode = try container.decodeIfPresent(LayoutMode.self, forKey: .layoutMode) ?? .stacked
    wifiQuality = try container.decodeIfPresent(PlaybackQuality.self, forKey: .wifiQuality) ?? .high
    mobileQuality = try container.decodeIfPresent(PlaybackQuality.self, forKey: .mobileQuality) ?? .economy
    danmakuFontSize = try container.decodeIfPresent(Double.self, forKey: .danmakuFontSize) ?? 20
    danmakuSpeed = try container.decodeIfPresent(Double.self, forKey: .danmakuSpeed) ?? 0.13
    danmakuOpacity = try container.decodeIfPresent(Double.self, forKey: .danmakuOpacity) ?? 0.9
    danmakuMaxLines = try container.decodeIfPresent(Int.self, forKey: .danmakuMaxLines) ?? 0
    danmakuMaxLength = try container.decodeIfPresent(Int.self, forKey: .danmakuMaxLength) ?? 0
    platformOrder = try container.decodeIfPresent([StreamPlatform].self, forKey: .platformOrder) ?? StreamPlatform.allCases
  }
}

final class NetworkQuality {
  static let shared = NetworkQuality()
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "MultiView.NetworkQuality")
  private var currentPath: NWPath?

  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      self?.queue.async {
        self?.currentPath = path
      }
    }
    monitor.start(queue: queue)
  }

  func activeQuality(settings: AppSettings) -> PlaybackQuality {
    var path: NWPath?
    queue.sync {
      path = currentPath ?? monitor.currentPath
    }
    if path?.usesInterfaceType(.cellular) == true || path?.isExpensive == true {
      return settings.mobileQuality
    }
    return settings.wifiQuality
  }
}

enum Store {
  private static let streamsKey = "native.streams.v1"
  private static let settingsKey = "native.settings.v4"

  static func loadStreams() -> [StreamItem] {
    guard let data = UserDefaults.standard.data(forKey: streamsKey),
          let streams = try? JSONDecoder().decode([StreamItem].self, from: data) else {
      return []
    }
    return streams
  }

  static func saveStreams(_ streams: [StreamItem]) {
    if let data = try? JSONEncoder().encode(streams) {
      UserDefaults.standard.set(data, forKey: streamsKey)
    }
  }

  static func loadSettings() -> AppSettings {
    guard let data = UserDefaults.standard.data(forKey: settingsKey),
          var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
      return AppSettings()
    }
    let merged = settings.platformOrder + StreamPlatform.allCases
    settings.platformOrder = merged.reduce(into: [StreamPlatform]()) { result, platform in
      if !result.contains(platform) {
        result.append(platform)
      }
    }
    return settings
  }

  static func saveSettings(_ settings: AppSettings) {
    if let data = try? JSONEncoder().encode(settings) {
      UserDefaults.standard.set(data, forKey: settingsKey)
    }
  }
}

enum StreamVolumeStore {
  private static let key = "native.streamVolumes.v1"

  static func volume(for stream: StreamItem) -> Float {
    let volumes = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    return Float(volumes[storageKey(for: stream)] ?? 1)
  }

  static func setVolume(_ volume: Float, for stream: StreamItem) {
    var volumes = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    volumes[storageKey(for: stream)] = Double(min(1, max(0, volume)))
    UserDefaults.standard.set(volumes, forKey: key)
  }

  static func remove(_ stream: StreamItem) {
    var volumes = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    volumes.removeValue(forKey: storageKey(for: stream))
    UserDefaults.standard.set(volumes, forKey: key)
  }

  private static func storageKey(for stream: StreamItem) -> String {
    "\(stream.platform.rawValue):\(stream.channel.lowercased())"
  }
}

protocol AppStateDelegate: AnyObject {
  func appStateDidChange()
}

final class AppState {
  static let shared = AppState()

  weak var delegate: AppStateDelegate?
  var streams = Store.loadStreams() {
    didSet {
      Store.saveStreams(streams)
      delegate?.appStateDidChange()
    }
  }
  var settings = Store.loadSettings() {
    didSet {
      Store.saveSettings(settings)
      delegate?.appStateDidChange()
    }
  }

  func add(platform: StreamPlatform, channel rawChannel: String) {
    let channel = rawChannel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !channel.isEmpty else { return }
    if streams.contains(where: { $0.platform == platform && $0.channel.lowercased() == channel.lowercased() }) {
      return
    }
    streams.append(StreamItem(id: UUID().uuidString, platform: platform, channel: channel))
  }

  func remove(_ stream: StreamItem) {
    StreamVolumeStore.remove(stream)
    streams.removeAll { $0.id == stream.id }
  }
}

final class MainTabController: UITabBarController, UITabBarControllerDelegate, AppStateDelegate {
  private let viewVC = ViewingController()
  private let rankingVC = RankingController()
  private let followingVC = FollowingController()
  private let settingsVC = SettingsController()

  override func viewDidLoad() {
    super.viewDidLoad()
    AppState.shared.delegate = self
    delegate = self
    tabBar.isTranslucent = true
    tabBar.tintColor = .systemBlue
    tabBar.standardAppearance = glassTabAppearance()
    if #available(iOS 15.0, *) {
      tabBar.scrollEdgeAppearance = tabBar.standardAppearance
    }

    followingVC.tabBarItem = UITabBarItem(title: "フォロー", image: UIImage(systemName: "antenna.radiowaves.left.and.right"), tag: 0)
    rankingVC.tabBarItem = UITabBarItem(title: "ランキング", image: UIImage(systemName: "chart.bar"), tag: 1)
    viewVC.tabBarItem = UITabBarItem(title: "視聴", image: UIImage(systemName: "square.grid.2x2"), tag: 2)
    settingsVC.tabBarItem = UITabBarItem(title: "設定", image: UIImage(systemName: "gearshape"), tag: 3)
    viewControllers = [followingVC, rankingVC, viewVC, settingsVC]
    selectedIndex = 2
  }

  func appStateDidChange() {
    viewVC.reload()
    rankingVC.reloadOrder()
    followingVC.reloadOrder()
    settingsVC.reload()
  }

  func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
    PlaybackCoordinator.shared.resumeAll()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      PlaybackCoordinator.shared.resumeAll()
    }
  }

  private func glassTabAppearance() -> UITabBarAppearance {
    let appearance = UITabBarAppearance()
    appearance.configureWithDefaultBackground()
    appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
    appearance.backgroundColor = UIColor.black.withAlphaComponent(0.35)
    return appearance
  }
}

// Non-official TwitCasting comment stream. Runs natively (no WebView CORS) and
// pushes comments into the hosted player's danmaku via MultiViewEmitComment.
final class TwitcastingChatClient {
  private let channel: String
  private let onComment: (String, String) -> Void
  private var socket: URLSessionWebSocketTask?
  private var stopped = false
  private var retryWork: DispatchWorkItem?

  init(channel: String, onComment: @escaping (String, String) -> Void) {
    self.channel = channel.trimmingCharacters(in: .whitespacesAndNewlines)
    self.onComment = onComment
    start()
  }

  func stop() {
    stopped = true
    retryWork?.cancel()
    retryWork = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
  }

  private func scheduleRetry() {
    guard !stopped else { return }
    let work = DispatchWorkItem { [weak self] in self?.start() }
    retryWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
  }

  private func start() {
    guard !stopped, !channel.isEmpty else { return }
    guard let encoded = channel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          let url = URL(string: "https://frontendapi.twitcasting.tv/users/\(encoded)/latest-movie") else { return }
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
      guard let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let movie = json["movie"] as? [String: Any],
            let movieId = Self.stringValue(movie["id"]) else {
        DispatchQueue.main.async { self?.scheduleRetry() }
        return
      }
      DispatchQueue.main.async { self?.fetchSubscribeURL(movieId: movieId) }
    }.resume()
  }

  private func fetchSubscribeURL(movieId: String) {
    guard !stopped, let url = URL(string: "https://twitcasting.tv/eventpubsuburl.php") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let encodedId = movieId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? movieId
    request.httpBody = "movie_id=\(encodedId)".data(using: .utf8)
    URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
      guard let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let urlString = json["url"] as? String,
            let wsURL = URL(string: urlString) else {
        DispatchQueue.main.async { self?.scheduleRetry() }
        return
      }
      DispatchQueue.main.async { self?.connect(wsURL: wsURL) }
    }.resume()
  }

  private func connect(wsURL: URL) {
    guard !stopped else { return }
    let task = URLSession.shared.webSocketTask(with: wsURL)
    socket = task
    task.resume()
    receive()
  }

  private func receive() {
    socket?.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let message):
        switch message {
        case .string(let text):
          self.handle(text)
        case .data(let data):
          if let text = String(data: data, encoding: .utf8) { self.handle(text) }
        @unknown default:
          break
        }
        DispatchQueue.main.async { [weak self] in
          guard let self, !self.stopped else { return }
          self.receive()
        }
      case .failure:
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.socket = nil
          self.scheduleRetry()
        }
      }
    }
  }

  private func handle(_ text: String) {
    guard let data = text.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
    for item in arr {
      guard (item["type"] as? String) == "comment",
            let message = item["message"] as? String, !message.isEmpty else { continue }
      let author = (item["author"] as? [String: Any])?["name"] as? String ?? ""
      onComment(message, author)
    }
  }

  private static func stringValue(_ value: Any?) -> String? {
    if let s = value as? String { return s }
    if let i = value as? Int { return String(i) }
    if let n = value as? NSNumber { return n.stringValue }
    return nil
  }
}

final class PlayerWebView: WKWebView, PlaybackResumable, PlaybackStoppable, AudioControllable, WKNavigationDelegate {
  private let playAudio: Bool
  private var playbackVolume: Float
  private var isStopped = false
  private let stream: StreamItem
  private let showChat: Bool
  private var twitcastingChat: TwitcastingChatClient?
  private var twitcastingStarted = false

  init(stream: StreamItem, settings: AppSettings) {
    playAudio = settings.playAudio
    playbackVolume = StreamVolumeStore.volume(for: stream)
    self.stream = stream
    self.showChat = settings.showChat
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    config.websiteDataStore = .default()
    if stream.platform == .niconico {
      config.userContentController.addUserScript(WKUserScript(source: PlayerWebView.niconicoPopupBlockerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }
    super.init(frame: .zero, configuration: config)
    isOpaque = false
    backgroundColor = .black
    scrollView.backgroundColor = .black
    scrollView.contentInsetAdjustmentBehavior = .never
    navigationDelegate = self
    PlaybackCoordinator.shared.register(self)
    load(stream: stream, settings: settings)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func load(stream: StreamItem, settings: AppSettings) {
    if stream.platform == .niconico {
      load(URLRequest(url: URL(string: "https://live.nicovideo.jp/watch/\(stream.channel)")!))
      return
    }
    var components = URLComponents(string: "https://tonton888115.github.io/MultiView/player.html")!
    components.queryItems = [
      URLQueryItem(name: "platform", value: stream.platform.rawValue),
      URLQueryItem(name: "channel", value: stream.channel),
      URLQueryItem(name: "chat", value: settings.showChat ? "1" : "0"),
      URLQueryItem(name: "fs", value: String(settings.danmakuFontSize)),
      URLQueryItem(name: "sp", value: String(settings.danmakuSpeed)),
      URLQueryItem(name: "op", value: String(settings.danmakuOpacity)),
      URLQueryItem(name: "ml", value: String(settings.danmakuMaxLines)),
      URLQueryItem(name: "mlen", value: String(settings.danmakuMaxLength)),
      URLQueryItem(name: "audio", value: settings.playAudio ? "1" : "0"),
      URLQueryItem(name: "quality", value: NetworkQuality.shared.activeQuality(settings: settings).rawValue),
      URLQueryItem(name: "vol", value: String(StreamVolumeStore.volume(for: stream))),
      URLQueryItem(name: "proxy", value: settings.proxyUrl.trimmingCharacters(in: .whitespacesAndNewlines))
    ]
    if let url = components.url {
      load(URLRequest(url: url))
    }
  }

  func resumePlayback() {
    guard !isStopped else { return }
    let shouldMute = playAudio ? "false" : "true"
    let volume = playAudio ? playbackVolume : 0
    let script = """
    (function(){
      document.body.classList.add('audio-started');
      document.querySelectorAll('video,audio').forEach(function(media){
        try {
          media.muted = \(shouldMute);
          media.volume = \(volume);
          var play = media.play && media.play();
          if (play && play.catch) play.catch(function(){});
        } catch(e) {}
      });
      document.querySelectorAll('iframe').forEach(function(frame){
        try { frame.contentWindow.postMessage({type:'volume', volume:\(volume)}, '*'); } catch(e) {}
        try { frame.contentWindow.postMessage({type:'play'}, '*'); } catch(e) {}
      });
    })();
    """
    evaluateJavaScript(script)
  }

  func setPlaybackVolume(_ volume: Float) {
    playbackVolume = min(1, max(0, volume))
    resumePlayback()
  }

  func stopPlayback() {
    isStopped = true
    twitcastingChat?.stop()
    twitcastingChat = nil
    stopLoading()
    evaluateJavaScript("""
    document.querySelectorAll('video,audio').forEach(function(media){
      try { media.pause(); media.src = ''; media.load(); } catch(e) {}
    });
    document.querySelectorAll('iframe').forEach(function(frame){
      try { frame.src = 'about:blank'; } catch(e) {}
    });
    """)
    loadHTMLString("", baseURL: nil)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    startTwitcastingChatIfNeeded()
  }

  private func startTwitcastingChatIfNeeded() {
    guard stream.platform == .twitcasting, showChat, !twitcastingStarted else { return }
    twitcastingStarted = true
    twitcastingChat = TwitcastingChatClient(channel: stream.channel) { [weak self] message, user in
      self?.emitComment(message, user)
    }
  }

  private func emitComment(_ message: String, _ user: String) {
    let js = "window.MultiViewEmitComment && window.MultiViewEmitComment('\(Self.jsEscape(message))', '\(Self.jsEscape(user))');"
    DispatchQueue.main.async { [weak self] in
      self?.evaluateJavaScript(js)
    }
  }

  private static func jsEscape(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\u{2028}", with: " ")
      .replacingOccurrences(of: "\u{2029}", with: " ")
  }

  private static let niconicoPopupBlockerScript = """
  (function(){
    function hideComfortPopup(){
      var words = ['快適視聴してみませんか', '快適視聴', 'プレミアム会員'];
      var nodes = Array.prototype.slice.call(document.querySelectorAll('[role="dialog"], dialog, [class*="modal"], [class*="Modal"], [class*="popup"], [class*="Popup"], [class*="overlay"], [class*="Overlay"]'));
      nodes.forEach(function (node) {
        var text = node.innerText || node.textContent || '';
        if (words.some(function (word) { return text.indexOf(word) !== -1; })) {
          node.style.setProperty('display', 'none', 'important');
          node.style.setProperty('visibility', 'hidden', 'important');
          node.style.setProperty('pointer-events', 'none', 'important');
        }
      });
    }
    hideComfortPopup();
    new MutationObserver(hideComfortPopup).observe(document.documentElement, { childList:true, subtree:true });
  })();
  """

}

final class NiconicoNativePlayerView: UIView, PlaybackResumable, PlaybackStoppable, AudioControllable {
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

  init(stream: StreamItem, settings: AppSettings) {
    self.stream = stream
    self.settings = settings
    self.channel = stream.channel
    self.playbackVolume = StreamVolumeStore.volume(for: stream)
    super.init(frame: .zero)
    backgroundColor = .black

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
    player.pause()
    player.replaceCurrentItem(with: nil)
    keepSeatTimer?.invalidate()
    keepSeatTimer = nil
    ndgrCommentTask?.cancel()
    ndgrCommentTask = nil
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

  func setPlaybackVolume(_ volume: Float) {
    playbackVolume = min(1, max(0, volume))
    player.volume = settings.playAudio ? playbackVolume : 0
    fallbackWebView?.setPlaybackVolume(playbackVolume)
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
    var request = URLRequest(url: url)
    request.setValue(NiconicoNativePlayerView.userAgent, forHTTPHeaderField: "User-Agent")
    pageTask = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
      guard let self else { return }
      self.pageTask = nil
      self.isLoading = false
      if let error {
        self.installFallback("ニコ生ページ取得失敗: \(error.localizedDescription)")
        return
      }
      guard let data, let html = String(data: data, encoding: .utf8) else {
        self.installFallback("ニコ生ページを読めません")
        return
      }
      do {
        let watch = try self.parseWatchData(from: html)
        self.connect(webSocketURL: watch.webSocketURL, frontendId: watch.frontendId)
      } catch {
        self.installFallback("ニコ生の再生情報を取得できません")
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
    request.setValue(NiconicoNativePlayerView.userAgent, forHTTPHeaderField: "User-Agent")
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
        self.socketTask = nil
        if self.player.currentItem == nil {
          self.installFallback("ニコ生WebSocket切断: \(error.localizedDescription)")
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
      let cookies = parseStreamCookies(payload["cookies"], for: uri)
      applyNiconicoCookies(cookies)
      play(hlsURL: uri, cookies: cookies)
    }
    if type == "error",
       let payload = json["data"] as? [String: Any],
       let code = payload["code"] as? String {
      showStatus("ニコ生エラー: \(code)")
    }
    if type == "disconnect" {
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
        "AVURLAssetHTTPHeaderFieldsKey": self.niconicoPlaybackHeaders()
      ]
      if !cookies.isEmpty {
        assetOptions[AVURLAssetHTTPCookiesKey] = cookies
      }
      let asset = AVURLAsset(url: hlsURL, options: assetOptions)
      let item = AVPlayerItem(asset: asset)
      item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
      item.preferredPeakBitRate = NetworkQuality.shared.activeQuality(settings: self.settings).preferredPeakBitRate
      self.itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
        if item.status == .failed {
          DispatchQueue.main.async {
            self?.showStatus(item.error?.localizedDescription ?? "ニコ生の再生に失敗しました")
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
        self?.showStatus(error?.localizedDescription ?? "ニコ生の再生が停止しました")
      }
      self.player.replaceCurrentItem(with: item)
      self.player.isMuted = !self.settings.playAudio
      self.player.volume = self.settings.playAudio ? self.playbackVolume : 0
      self.player.play()
    }
  }

  private func niconicoPlaybackHeaders() -> [String: String] {
    var headers = [
      "User-Agent": NiconicoNativePlayerView.userAgent,
      "Referer": watchPageURL?.absoluteString ?? "https://live.nicovideo.jp/",
      "Origin": "https://live.nicovideo.jp"
    ]
    let cookieURL = URL(string: "https://live.nicovideo.jp/")!
    if let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL), !cookies.isEmpty {
      headers["Cookie"] = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    return headers
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
      self.showStatus(reason)
      self.player.pause()
      self.player.replaceCurrentItem(with: nil)
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
    ndgrCommentTask = Task { [weak self] in
      guard let self else { return }
      await self.streamNDGRView(viewURI: viewURI)
    }
  }

  private func streamNDGRView(viewURI: String) async {
    var nextAt: String? = "now"
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
        for try await message in protobufMessages(from: url) {
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
        }
      } catch {
        if Task.isCancelled || error is CancellationError {
          return
        }
        nextAt = requestAt ?? "now"
        showStatus("ニコ生コメント取得失敗: \(error.localizedDescription)")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        continue
      }
      if nextAt == nil {
        break
      }
    }
  }

  private func streamNDGRSegment(uri: String) async {
    defer {
      activeSegmentURIs.remove(uri)
      segmentTasks.removeValue(forKey: uri)
    }
    guard let url = URL(string: uri) else { return }
    do {
      for try await message in protobufMessages(from: url) {
        if let text = parseNDGRCommentText(fromChunkedMessage: message) {
          emitDanmaku(text)
        }
      }
    } catch {
      showStatus("ニコ生コメント受信失敗: \(error.localizedDescription)")
    }
  }

  private func protobufMessages(from url: URL) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var request = URLRequest(url: url)
          self.niconicoPlaybackHeaders().forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
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

  private func parseWatchData(from html: String) throws -> (webSocketURL: URL, frontendId: String?) {
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
      return (url, frontendId)
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
    return (url, frontendId)
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

  private func emitDanmaku(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if settings.danmakuMaxLength > 0, trimmed.count > settings.danmakuMaxLength {
      return
    }
    DispatchQueue.main.async {
      guard self.danmakuView.bounds.height > 0, self.danmakuView.bounds.width > 0 else { return }
      let fontSize = CGFloat(self.settings.danmakuFontSize)
      let lineHeight = fontSize + 8
      let maxLines = self.settings.danmakuMaxLines > 0
        ? self.settings.danmakuMaxLines
        : max(1, Int(self.danmakuView.bounds.height / lineHeight))
      let label = UILabel()
      label.text = trimmed
      label.font = .systemFont(ofSize: fontSize, weight: .bold)
      label.textColor = UIColor.white.withAlphaComponent(self.settings.danmakuOpacity)
      label.layer.shadowColor = UIColor.black.cgColor
      label.layer.shadowRadius = 2
      label.layer.shadowOpacity = 1
      label.layer.shadowOffset = CGSize(width: 1, height: 1)
      label.sizeToFit()
      let lane = self.laneCursor % maxLines
      self.laneCursor += 1
      let y = CGFloat(lane) * lineHeight + 6
      let startX = self.danmakuView.bounds.width + 12
      label.frame.origin = CGPoint(x: startX, y: y)
      self.danmakuView.addSubview(label)
      let travel = startX + label.bounds.width + 24
      let pixelsPerSecond = max(35, self.danmakuView.bounds.width * CGFloat(self.settings.danmakuSpeed))
      let duration = TimeInterval(travel / pixelsPerSecond)
      UIView.animate(withDuration: duration, delay: 0, options: [.curveLinear]) {
        label.frame.origin.x = -label.bounds.width - 12
      } completion: { _ in
        label.removeFromSuperview()
      }
    }
  }

  private func showStatus(_ text: String) {
    DispatchQueue.main.async {
      self.statusLabel.text = text
      self.statusLabel.isHidden = false
    }
  }

  private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
}

final class KickNativePlayerView: UIView, PlaybackResumable, PlaybackStoppable, AudioControllable {
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

  func stopPlayback() {
    isStopped = true
    channelTask?.cancel()
    channelTask = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    socketTask?.cancel(with: .goingAway, reason: nil)
    socketTask = nil
    chatroomID = nil
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
      if let chatroomID = channelInfo.chatroomID {
        self.connectKickComments(chatroomID: chatroomID)
      }
      guard let hlsURL = channelInfo.hlsURL else {
        self.installFallback("Kick HLS URLを取得できません")
        return
      }
      self.play(hlsURL: hlsURL)
    }
    channelTask?.resume()
  }

  private func play(hlsURL: URL) {
    DispatchQueue.main.async {
      guard !self.isStopped else { return }
      self.statusLabel.isHidden = true
      let asset = AVURLAsset(url: hlsURL, options: [
        "AVURLAssetHTTPHeaderFieldsKey": self.kickPlaybackHeaders()
      ])
      let item = AVPlayerItem(asset: asset)
      item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
      item.preferredPeakBitRate = NetworkQuality.shared.activeQuality(settings: self.settings).preferredPeakBitRate
      self.itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
        if item.status == .failed {
          DispatchQueue.main.async {
            self?.installFallback(item.error?.localizedDescription ?? "Kickネイティブ再生に失敗しました")
          }
        } else if item.status == .readyToPlay {
          DispatchQueue.main.async {
            self?.resumePlayback()
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
        self?.installFallback(error?.localizedDescription ?? "Kickネイティブ再生が停止しました")
      }
      self.player.replaceCurrentItem(with: item)
      self.player.isMuted = !self.settings.playAudio
      self.player.volume = self.settings.playAudio ? self.playbackVolume : 0
      self.player.play()
    }
  }

  private func installFallback(_ reason: String) {
    DispatchQueue.main.async {
      guard !self.isStopped, self.fallbackWebView == nil else { return }
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
    guard let url = URL(string: "https://kick.com/"),
          let cookies = HTTPCookieStorage.shared.cookies(for: url),
          !cookies.isEmpty else { return nil }
    return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
  }

  private func connectKickComments(chatroomID: String) {
    guard settings.showChat, !isStopped else { return }
    self.chatroomID = chatroomID
    socketTask?.cancel(with: .goingAway, reason: nil)
    guard let url = URL(string: "wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679?protocol=7&client=ios-native&version=1.0&flash=false") else { return }
    let task = URLSession.shared.webSocketTask(with: url)
    socketTask = task
    task.resume()
    let payload: [String: Any] = [
      "event": "pusher:subscribe",
      "data": [
        "auth": "",
        "channel": "chatrooms.\(chatroomID).v2"
      ]
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let text = String(data: data, encoding: .utf8) {
      task.send(.string(text)) { _ in }
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
    guard event.contains("ChatMessage") else { return }
    let payloadData: Data?
    if let raw = json["data"] as? String {
      payloadData = raw.data(using: .utf8)
    } else if let raw = json["data"] as? [String: Any] {
      payloadData = try? JSONSerialization.data(withJSONObject: raw)
    } else {
      payloadData = nil
    }
    guard let payloadData,
          let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
          let content = (payload["content"] as? String) ?? (payload["message"] as? String) else { return }
    emitDanmaku(Self.kickPlain(content))
  }

  private func emitDanmaku(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if settings.danmakuMaxLength > 0, trimmed.count > settings.danmakuMaxLength {
      return
    }
    DispatchQueue.main.async {
      guard self.danmakuView.bounds.height > 0, self.danmakuView.bounds.width > 0 else { return }
      let fontSize = CGFloat(self.settings.danmakuFontSize)
      let lineHeight = fontSize + 8
      let maxLines = self.settings.danmakuMaxLines > 0
        ? self.settings.danmakuMaxLines
        : max(1, Int(self.danmakuView.bounds.height / lineHeight))
      let label = UILabel()
      label.text = trimmed
      label.font = .systemFont(ofSize: fontSize, weight: .bold)
      label.textColor = UIColor.white.withAlphaComponent(self.settings.danmakuOpacity)
      label.layer.shadowColor = UIColor.black.cgColor
      label.layer.shadowRadius = 2
      label.layer.shadowOpacity = 1
      label.layer.shadowOffset = CGSize(width: 1, height: 1)
      label.sizeToFit()
      let lane = self.laneCursor % maxLines
      self.laneCursor += 1
      let y = CGFloat(lane) * lineHeight + 6
      let startX = self.danmakuView.bounds.width + 12
      label.frame.origin = CGPoint(x: startX, y: y)
      self.danmakuView.addSubview(label)
      let travel = startX + label.bounds.width + 24
      let pixelsPerSecond = max(35, self.danmakuView.bounds.width * CGFloat(self.settings.danmakuSpeed))
      let duration = TimeInterval(travel / pixelsPerSecond)
      UIView.animate(withDuration: duration, delay: 0, options: [.curveLinear]) {
        label.frame.origin.x = -label.bounds.width - 12
      } completion: { _ in
        label.removeFromSuperview()
      }
    }
  }

  private static func kickPlain(_ content: String) -> String {
    content.replacingOccurrences(of: #"\[emote:\d+:[^\]]+\]"#, with: "", options: .regularExpression)
  }

  private static func extractChannelInfo(from data: Data) -> (hlsURL: URL?, chatroomID: String?) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
    var hlsURL: URL?
    var chatroomID: String?
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
    return (hlsURL, chatroomID)
  }

  private static func stringValue(_ value: Any) -> String? {
    if let string = value as? String { return string }
    if let int = value as? Int { return String(int) }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }

  private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
}

// Native Twitch playback, emulating the official app: fetch a PlaybackAccessToken
// over GraphQL, build the usher.ttvnw.net HLS master playlist, and play it with
// AVPlayer. Anonymous IRC supplies danmaku comments. Falls back to the web embed.
final class TwitchNativePlayerView: UIView, PlaybackResumable, PlaybackStoppable, AudioControllable {
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
  private var itemStatusObservation: NSKeyValueObservation?
  private var itemFailedObserver: NSObjectProtocol?
  private var fallbackWebView: PlayerWebView?
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

  func stopPlayback() {
    isStopped = true
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

  private func loadNativeStream() {
    guard !isStopped, !isLoading, fallbackWebView == nil else { return }
    let channel = Self.normalizeChannel(stream.channel)
    guard !channel.isEmpty else {
      installFallback("Twitchチャンネル名が不正です")
      return
    }
    isLoading = true
    showStatus("Twitchをネイティブ再生で読み込み中")
    requestAccessToken(channel: channel)
  }

  private func requestAccessToken(channel: String) {
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
      if let error {
        self.installFallback("Twitchトークン取得失敗: \(error.localizedDescription)")
        return
      }
      guard let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = json["data"] as? [String: Any],
            let token = payload["streamPlaybackAccessToken"] as? [String: Any],
            let value = token["value"] as? String,
            let signature = token["signature"] as? String else {
        self.installFallback("Twitchの配信情報を取得できません")
        return
      }
      guard let usherURL = Self.buildUsherURL(channel: channel, token: value, signature: signature) else {
        self.installFallback("Twitch再生URLを構築できません")
        return
      }
      self.isLoading = false
      self.connectTwitchChat(channel: channel)
      self.play(hlsURL: usherURL)
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

  private func play(hlsURL: URL) {
    DispatchQueue.main.async {
      guard !self.isStopped else { return }
      self.statusLabel.isHidden = true
      let asset = AVURLAsset(url: hlsURL, options: [
        "AVURLAssetHTTPHeaderFieldsKey": self.twitchPlaybackHeaders()
      ])
      let item = AVPlayerItem(asset: asset)
      item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
      item.preferredPeakBitRate = NetworkQuality.shared.activeQuality(settings: self.settings).preferredPeakBitRate
      self.itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
        if item.status == .failed {
          DispatchQueue.main.async {
            self?.installFallback(item.error?.localizedDescription ?? "Twitchネイティブ再生に失敗しました")
          }
        } else if item.status == .readyToPlay {
          DispatchQueue.main.async {
            self?.resumePlayback()
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
        self?.installFallback(error?.localizedDescription ?? "Twitchネイティブ再生が停止しました")
      }
      self.player.replaceCurrentItem(with: item)
      self.player.isMuted = !self.settings.playAudio
      self.player.volume = self.settings.playAudio ? self.playbackVolume : 0
      self.player.play()
    }
  }

  private func installFallback(_ reason: String) {
    DispatchQueue.main.async {
      guard !self.isStopped, self.fallbackWebView == nil else { return }
      self.isLoading = false
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
    guard settings.showChat, !isStopped, fallbackWebView == nil else { return }
    chatChannel = channel
    chatSocket?.cancel(with: .goingAway, reason: nil)
    guard let url = URL(string: "wss://irc-ws.chat.twitch.tv:443") else { return }
    let task = URLSession.shared.webSocketTask(with: url)
    chatSocket = task
    task.resume()
    let nick = "justinfan\(Int.random(in: 10000..<1_000_000))"
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
      guard let privmsg = rawLine.range(of: " PRIVMSG "),
            let bodyRange = rawLine.range(of: " :", range: privmsg.lowerBound..<rawLine.endIndex) else { continue }
      let message = String(rawLine[bodyRange.upperBound...])
      emitDanmaku(message)
    }
  }

  private func emitDanmaku(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if settings.danmakuMaxLength > 0, trimmed.count > settings.danmakuMaxLength {
      return
    }
    DispatchQueue.main.async {
      guard self.danmakuView.bounds.height > 0, self.danmakuView.bounds.width > 0 else { return }
      let fontSize = CGFloat(self.settings.danmakuFontSize)
      let lineHeight = fontSize + 8
      let maxLines = self.settings.danmakuMaxLines > 0
        ? self.settings.danmakuMaxLines
        : max(1, Int(self.danmakuView.bounds.height / lineHeight))
      let label = UILabel()
      label.text = trimmed
      label.font = .systemFont(ofSize: fontSize, weight: .bold)
      label.textColor = UIColor.white.withAlphaComponent(self.settings.danmakuOpacity)
      label.layer.shadowColor = UIColor.black.cgColor
      label.layer.shadowRadius = 2
      label.layer.shadowOpacity = 1
      label.layer.shadowOffset = CGSize(width: 1, height: 1)
      label.sizeToFit()
      let lane = self.laneCursor % maxLines
      self.laneCursor += 1
      let y = CGFloat(lane) * lineHeight + 6
      let startX = self.danmakuView.bounds.width + 12
      label.frame.origin = CGPoint(x: startX, y: y)
      self.danmakuView.addSubview(label)
      let travel = startX + label.bounds.width + 24
      let pixelsPerSecond = max(35, self.danmakuView.bounds.width * CGFloat(self.settings.danmakuSpeed))
      let duration = TimeInterval(travel / pixelsPerSecond)
      UIView.animate(withDuration: duration, delay: 0, options: [.curveLinear]) {
        label.frame.origin.x = -label.bounds.width - 12
      } completion: { _ in
        label.removeFromSuperview()
      }
    }
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

final class MultiPlayerWebView: WKWebView, WKScriptMessageHandler, PlaybackResumable, PlaybackStoppable, AudioControllable {
  private let playAudio: Bool
  private var playbackVolume: Float = 1
  private var isStopped = false

  init(streams: [StreamItem], settings: AppSettings) {
    playAudio = settings.playAudio
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    config.websiteDataStore = .default()
    super.init(frame: .zero, configuration: config)
    isOpaque = false
    backgroundColor = .black
    scrollView.backgroundColor = .black
    scrollView.contentInsetAdjustmentBehavior = .never
    configuration.userContentController.add(self, name: "multiview")
    PlaybackCoordinator.shared.register(self)
    load(streams: streams, settings: settings)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    configuration.userContentController.removeScriptMessageHandler(forName: "multiview")
  }

  private func load(streams: [StreamItem], settings: AppSettings) {
    let encodedStreams = streams
      .map { "\($0.platform.rawValue):\($0.channel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.channel)" }
      .joined(separator: ",")
    var components = URLComponents(string: "https://tonton888115.github.io/MultiView/multiview.html")!
    components.queryItems = [
      URLQueryItem(name: "streams", value: encodedStreams),
      URLQueryItem(name: "volumes", value: Self.encodedVolumes(for: streams)),
      URLQueryItem(name: "layout", value: settings.layoutMode.rawValue),
      URLQueryItem(name: "audio", value: settings.playAudio ? "1" : "0"),
      URLQueryItem(name: "quality", value: NetworkQuality.shared.activeQuality(settings: settings).rawValue),
      URLQueryItem(name: "chat", value: settings.showChat ? "1" : "0"),
      URLQueryItem(name: "proxy", value: settings.proxyUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
      URLQueryItem(name: "fs", value: String(settings.danmakuFontSize)),
      URLQueryItem(name: "sp", value: String(settings.danmakuSpeed)),
      URLQueryItem(name: "op", value: String(settings.danmakuOpacity)),
      URLQueryItem(name: "ml", value: String(settings.danmakuMaxLines)),
      URLQueryItem(name: "mlen", value: String(settings.danmakuMaxLength))
    ]
    if let url = components.url {
      load(URLRequest(url: url))
    }
  }

  func resumePlayback() {
    guard !isStopped else { return }
    let shouldMute = playAudio ? "false" : "true"
    let volume = playAudio ? playbackVolume : 0
    let script = """
    (function(){
      document.body.classList.add('audio-started');
      document.querySelectorAll('video,audio').forEach(function(media){
        try {
          media.muted = \(shouldMute);
          media.volume = \(volume);
          var play = media.play && media.play();
          if (play && play.catch) play.catch(function(){});
        } catch(e) {}
      });
      document.querySelectorAll('iframe').forEach(function(frame){
        try { frame.contentWindow.postMessage({type:'volume', volume:\(volume)}, '*'); } catch(e) {}
        try { frame.contentWindow.postMessage({type:'play'}, '*'); } catch(e) {}
      });
    })();
    """
    evaluateJavaScript(script)
  }

  func setPlaybackVolume(_ volume: Float) {
    playbackVolume = min(1, max(0, volume))
    resumePlayback()
  }

  func setStreamVolume(_ volume: Float, for stream: StreamItem) {
    let safeKey = Self.jsString(Self.streamKey(for: stream))
    let safeVolume = min(1, max(0, volume))
    evaluateJavaScript("""
    (function(){
      var payload = {type:'volume', key:'\(safeKey)', volume:\(safeVolume)};
      window.dispatchEvent(new MessageEvent('message', {data: payload}));
    })();
    """)
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == "multiview",
          let payload = message.body as? [String: Any],
          let type = payload["type"] as? String,
          type == "remove",
          let platformRaw = payload["platform"] as? String,
          let platform = StreamPlatform(rawValue: platformRaw),
          let channel = payload["channel"] as? String else { return }
    if let stream = AppState.shared.streams.first(where: {
      $0.platform == platform && $0.channel.lowercased() == channel.lowercased()
    }) {
      AppState.shared.remove(stream)
    }
  }

  func stopPlayback() {
    isStopped = true
    stopLoading()
    evaluateJavaScript("""
    document.querySelectorAll('video,audio').forEach(function(media){
      try { media.pause(); media.src = ''; media.load(); } catch(e) {}
    });
    document.querySelectorAll('iframe').forEach(function(frame){
      try { frame.src = 'about:blank'; } catch(e) {}
    });
    """)
    loadHTMLString("", baseURL: nil)
  }

  private static func streamKey(for stream: StreamItem) -> String {
    "\(stream.platform.rawValue):\(stream.channel.lowercased())"
  }

  private static func encodedVolumes(for streams: [StreamItem]) -> String {
    streams
      .map {
        let key = streamKey(for: $0).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? streamKey(for: $0)
        return "\(key)=\(StreamVolumeStore.volume(for: $0))"
      }
      .joined(separator: ",")
  }

  private static func jsString(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'")
      .replacingOccurrences(of: "\n", with: " ")
  }
}

final class ViewingController: UIViewController {
  private let scrollView = UIScrollView()
  private let stack = UIStackView()
  private var focused: StreamItem?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)
    configureScroll()
    reload()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    PlaybackCoordinator.shared.resumeAll()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      PlaybackCoordinator.shared.resumeAll()
    }
  }

  func reload() {
    guard isViewLoaded else { return }
    clearStack()
    let streams = AppState.shared.streams
    if streams.isEmpty {
      stack.addArrangedSubview(emptyView())
      return
    }
    addPlaybackBar()
    if let focused, streams.contains(focused) {
      stack.addArrangedSubview(FocusedStreamView(stream: focused, onClose: { [weak self] in
        self?.focused = nil
        self?.reload()
      }))
      PlaybackCoordinator.shared.resumeAll()
      return
    }
    if streams.contains(where: { $0.platform.usesIndividualPlayer }) {
      addHybridPlayers(streams)
      PlaybackCoordinator.shared.resumeAll()
      return
    }
    addUnifiedPlayer(streams)
    PlaybackCoordinator.shared.resumeAll()
  }

  private func clearStack() {
    stack.arrangedSubviews.forEach { view in
      stopPlayback(in: view)
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }

  private func stopPlayback(in view: UIView) {
    (view as? PlaybackStoppable)?.stopPlayback()
    view.subviews.forEach { stopPlayback(in: $0) }
  }

  private func configureScroll() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scrollView)
    scrollView.addSubview(stack)
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 10),
      stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -10),
      stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -18)
    ])
  }

  private func addStackedCell(_ stream: StreamItem) {
    let cell = StreamCellView(stream: stream, onFocus: { [weak self] in
      self?.focused = stream
      self?.reload()
    })
    stack.addArrangedSubview(cell)
    cell.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 9 / 16).isActive = true
    cell.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
  }

  private func addUnifiedPlayer(_ streams: [StreamItem]) {
    let web = MultiPlayerWebView(streams: streams, settings: AppState.shared.settings)
    let host = UIView()
    host.backgroundColor = .black
    host.translatesAutoresizingMaskIntoConstraints = false
    web.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(web)
    stack.addArrangedSubview(host)
    NSLayoutConstraint.activate([
      web.topAnchor.constraint(equalTo: host.topAnchor),
      web.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      web.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      web.bottomAnchor.constraint(equalTo: host.bottomAnchor),
      host.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor)
    ])
  }

  private func addHybridPlayers(_ streams: [StreamItem]) {
    let individual = streams.filter { $0.platform.usesIndividualPlayer }
    let embeddable = streams.filter { !$0.platform.usesIndividualPlayer }
    if !embeddable.isEmpty {
      let web = MultiPlayerWebView(streams: embeddable, settings: AppState.shared.settings)
      let host = UIView()
      host.backgroundColor = .black
      host.translatesAutoresizingMaskIntoConstraints = false
      web.translatesAutoresizingMaskIntoConstraints = false
      host.addSubview(web)
      stack.addArrangedSubview(host)
      let rows = AppState.shared.settings.layoutMode == .grid ? ceil(Double(embeddable.count) / 2.0) : Double(embeddable.count)
      let heightMultiplier = AppState.shared.settings.layoutMode == .grid ? CGFloat(rows) * 9 / 32 : CGFloat(rows) * 9 / 16
      NSLayoutConstraint.activate([
        web.topAnchor.constraint(equalTo: host.topAnchor),
        web.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        web.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        web.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        host.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: heightMultiplier),
        host.heightAnchor.constraint(greaterThanOrEqualToConstant: embeddable.count == 1 ? 220 : 180)
      ])
    }
    if !individual.isEmpty {
      addCells(individual)
    }
  }

  private func addCells(_ streams: [StreamItem]) {
    if AppState.shared.settings.layoutMode == .grid {
      addGrid(streams)
      return
    }
    streams.forEach { addStackedCell($0) }
  }

  private func addPlaybackBar() {
    let host = UIView()
    host.translatesAutoresizingMaskIntoConstraints = false

    let row = UIStackView()
    row.axis = .horizontal
    row.spacing = 8
    row.alignment = .center
    row.distribution = .fill
    row.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(row)

    let playButton = playbackButton(title: " 全て再生", icon: "play.fill", color: .systemGreen) {
      PlaybackCoordinator.shared.resumeAll()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        PlaybackCoordinator.shared.resumeAll()
      }
    }
    let reloadButton = playbackButton(title: " 自動更新", icon: "arrow.clockwise", color: .systemBlue) { [weak self] in
      self?.reload()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        PlaybackCoordinator.shared.resumeAll()
      }
    }
    row.addArrangedSubview(playButton)
    row.addArrangedSubview(reloadButton)

    stack.addArrangedSubview(host)
    NSLayoutConstraint.activate([
      host.heightAnchor.constraint(equalToConstant: 38),
      row.centerYAnchor.constraint(equalTo: host.centerYAnchor),
      row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      playButton.heightAnchor.constraint(equalToConstant: 34),
      reloadButton.heightAnchor.constraint(equalToConstant: 34)
    ])
  }

  private func playbackButton(title: String, icon: String, color: UIColor, action: @escaping () -> Void) -> UIButton {
    let button = UIButton(type: .system)
    button.setImage(UIImage(systemName: icon), for: .normal)
    button.setTitle(title, for: .normal)
    button.tintColor = .white
    button.setTitleColor(.white, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
    button.backgroundColor = color.withAlphaComponent(0.85)
    button.layer.cornerRadius = 16
    button.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 14)
    button.addAction(UIAction { actionEvent in
      guard let sender = actionEvent.sender as? UIButton else {
        action()
        return
      }
      let originalTitle = sender.title(for: .normal)
      sender.alpha = 0.62
      sender.setTitle(" 実行中", for: .normal)
      action()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        sender.alpha = 1
        sender.setTitle(originalTitle, for: .normal)
      }
    }, for: .touchUpInside)
    return button
  }

  private func addCloseBar(_ streams: [StreamItem]) {
    let scroller = UIScrollView()
    scroller.showsHorizontalScrollIndicator = false
    scroller.translatesAutoresizingMaskIntoConstraints = false
    let row = UIStackView()
    row.axis = .horizontal
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    scroller.addSubview(row)

    streams.forEach { stream in
      let group = UIStackView()
      group.axis = .horizontal
      group.spacing = 2
      group.alignment = .fill
      group.backgroundColor = UIColor.white.withAlphaComponent(0.12)
      group.layer.cornerRadius = 15
      group.clipsToBounds = true

      let open = UIButton(type: .system)
      open.setTitle("\(stream.platform.label) / \(stream.channel)", for: .normal)
      open.setTitleColor(.white, for: .normal)
      open.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
      open.contentEdgeInsets = UIEdgeInsets(top: 7, left: 11, bottom: 7, right: 9)
      open.addAction(UIAction { [weak self] _ in
        self?.focused = stream
        self?.reload()
      }, for: .touchUpInside)

      let close = UIButton(type: .system)
      close.setImage(UIImage(systemName: "xmark"), for: .normal)
      close.tintColor = .white
      close.contentEdgeInsets = UIEdgeInsets(top: 7, left: 8, bottom: 7, right: 11)
      close.addAction(UIAction { _ in AppState.shared.remove(stream) }, for: .touchUpInside)

      group.addArrangedSubview(open)
      group.addArrangedSubview(close)
      row.addArrangedSubview(group)
    }

    stack.addArrangedSubview(scroller)
    NSLayoutConstraint.activate([
      scroller.heightAnchor.constraint(equalToConstant: 38),
      row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
      row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
      row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
      row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor)
    ])
  }

  private func addGrid(_ streams: [StreamItem]) {
    let rows = stride(from: 0, to: streams.count, by: 2).map { Array(streams[$0..<min($0 + 2, streams.count)]) }
    rows.forEach { rowStreams in
      let row = UIStackView()
      row.axis = .horizontal
      row.spacing = 10
      row.distribution = .fillEqually
      rowStreams.forEach { stream in
        row.addArrangedSubview(StreamCellView(stream: stream, onFocus: { [weak self] in
          self?.focused = stream
          self?.reload()
        }))
      }
      stack.addArrangedSubview(row)
      row.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 9 / 32).isActive = true
      row.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }
  }

  private func emptyView() -> UIView {
    let label = UILabel()
    label.text = "配信がありません\n＋やランキングから追加してください"
    label.textColor = .secondaryLabel
    label.textAlignment = .center
    label.numberOfLines = 0
    label.heightAnchor.constraint(equalToConstant: 420).isActive = true
    return label
  }
}

final class StreamCellView: UIView {
  private var autoHider: AutoHidingControls?

  init(stream: StreamItem, onFocus: @escaping () -> Void) {
    super.init(frame: .zero)
    backgroundColor = .black
    clipsToBounds = true
    layer.cornerRadius = 18
    layer.borderWidth = 0.5
    layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor

    let video: UIView
    if stream.platform == .niconico {
      video = NiconicoNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else if stream.platform == .kick {
      video = KickNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else if stream.platform == .twitch {
      video = TwitchNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else {
      video = PlayerWebView(stream: stream, settings: AppState.shared.settings)
    }
    let audio = video as? AudioControllable
    video.translatesAutoresizingMaskIntoConstraints = false
    addSubview(video)

    let focus = UIButton(type: .system)
    focus.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right"), for: .normal)
    focus.tintColor = .white
    focus.backgroundColor = UIColor.black.withAlphaComponent(0.38)
    focus.layer.cornerRadius = 16
    focus.addAction(UIAction { _ in onFocus() }, for: .touchUpInside)
    focus.translatesAutoresizingMaskIntoConstraints = false
    addSubview(focus)

    let remove = UIButton(type: .system)
    remove.setImage(UIImage(systemName: "xmark"), for: .normal)
    remove.tintColor = .white
    remove.backgroundColor = UIColor.black.withAlphaComponent(0.38)
    remove.layer.cornerRadius = 16
    remove.addAction(UIAction { _ in AppState.shared.remove(stream) }, for: .touchUpInside)
    remove.translatesAutoresizingMaskIntoConstraints = false
    addSubview(remove)

    let volume = VolumeOverlay(stream: stream) { value in
      audio?.setPlaybackVolume(value)
    }
    volume.translatesAutoresizingMaskIntoConstraints = false
    addSubview(volume)

    NSLayoutConstraint.activate([
      video.topAnchor.constraint(equalTo: topAnchor),
      video.leadingAnchor.constraint(equalTo: leadingAnchor),
      video.trailingAnchor.constraint(equalTo: trailingAnchor),
      video.bottomAnchor.constraint(equalTo: bottomAnchor),
      focus.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      focus.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -8),
      focus.widthAnchor.constraint(equalToConstant: 32),
      focus.heightAnchor.constraint(equalToConstant: 32),
      remove.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      remove.widthAnchor.constraint(equalToConstant: 32),
      remove.heightAnchor.constraint(equalToConstant: 32),
      volume.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      volume.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      volume.widthAnchor.constraint(equalToConstant: 42),
      volume.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.62)
    ])
    autoHider = AutoHidingControls(host: self, controls: [focus, remove, volume])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

}

final class VolumeOverlay: UIVisualEffectView {
  init(stream: StreamItem, onChange: @escaping (Float) -> Void) {
    super.init(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    clipsToBounds = true
    layer.cornerRadius = 18

    let icon = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
    icon.tintColor = .white
    icon.contentMode = .scaleAspectFit
    icon.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(icon)

    let slider = UISlider()
    slider.minimumValue = 0
    slider.maximumValue = 1
    slider.value = StreamVolumeStore.volume(for: stream)
    slider.minimumTrackTintColor = stream.platform.tint
    slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.28)
    slider.addAction(UIAction { action in
      guard let slider = action.sender as? UISlider else { return }
      StreamVolumeStore.setVolume(slider.value, for: stream)
      onChange(slider.value)
    }, for: .valueChanged)
    let thumbSize: CGFloat = 15
    let thumb = UIGraphicsImageRenderer(size: CGSize(width: thumbSize, height: thumbSize)).image { context in
      UIColor.white.setFill()
      context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: thumbSize, height: thumbSize))
    }
    slider.setThumbImage(thumb, for: .normal)
    slider.setThumbImage(thumb, for: .highlighted)
    slider.transform = CGAffineTransform(rotationAngle: -.pi / 2)
    slider.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(slider)

    NSLayoutConstraint.activate([
      icon.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      icon.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
      icon.widthAnchor.constraint(equalToConstant: 18),
      icon.heightAnchor.constraint(equalToConstant: 18),
      slider.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      slider.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -8),
      slider.widthAnchor.constraint(equalTo: contentView.heightAnchor, constant: -34),
      slider.heightAnchor.constraint(equalToConstant: 24)
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class FocusedStreamView: UIView {
  private let stream: StreamItem
  private let chatWeb: WKWebView?
  private let input = UITextField()
  private var autoHider: AutoHidingControls?

  init(stream: StreamItem, onClose: (() -> Void)?) {
    self.stream = stream
    let chatURL = FocusedStreamView.chatURL(for: stream)
    if let chatURL {
      let config = WKWebViewConfiguration()
      config.allowsInlineMediaPlayback = true
      config.websiteDataStore = .default()
      chatWeb = WKWebView(frame: .zero, configuration: config)
      chatWeb?.load(URLRequest(url: chatURL))
    } else {
      chatWeb = nil
    }
    super.init(frame: .zero)
    backgroundColor = .black
    heightAnchor.constraint(greaterThanOrEqualToConstant: 640).isActive = true

    let video: UIView
    if stream.platform == .niconico {
      video = NiconicoNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else if stream.platform == .kick {
      video = KickNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else if stream.platform == .twitch {
      video = TwitchNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else {
      video = PlayerWebView(stream: stream, settings: AppState.shared.settings)
    }
    let audio = video as? AudioControllable
    video.translatesAutoresizingMaskIntoConstraints = false
    addSubview(video)

    var closeButton: UIButton?
    if let onClose {
      let close = UIButton(type: .system)
      close.setImage(UIImage(systemName: "chevron.left"), for: .normal)
      close.tintColor = .white
      close.backgroundColor = UIColor.black.withAlphaComponent(0.38)
      close.layer.cornerRadius = 18
      close.addAction(UIAction { _ in onClose() }, for: .touchUpInside)
      close.translatesAutoresizingMaskIntoConstraints = false
      addSubview(close)
      closeButton = close
    }

    let remove = UIButton(type: .system)
    remove.setImage(UIImage(systemName: "xmark"), for: .normal)
    remove.tintColor = .white
    remove.backgroundColor = UIColor.black.withAlphaComponent(0.38)
    remove.layer.cornerRadius = 18
    remove.addAction(UIAction { _ in AppState.shared.remove(stream) }, for: .touchUpInside)
    remove.translatesAutoresizingMaskIntoConstraints = false
    addSubview(remove)

    let volume = VolumeOverlay(stream: stream) { value in
      audio?.setPlaybackVolume(value)
    }
    volume.translatesAutoresizingMaskIntoConstraints = false
    addSubview(volume)

    let chatPanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    chatPanel.translatesAutoresizingMaskIntoConstraints = false
    chatPanel.layer.cornerRadius = 18
    chatPanel.clipsToBounds = true
    addSubview(chatPanel)

    if let chatWeb {
      chatWeb.translatesAutoresizingMaskIntoConstraints = false
      chatPanel.contentView.addSubview(chatWeb)
    } else {
      let label = UILabel()
      label.text = "このサービスはチャット入力未対応です"
      label.textColor = .secondaryLabel
      label.textAlignment = .center
      label.translatesAutoresizingMaskIntoConstraints = false
      chatPanel.contentView.addSubview(label)
      NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: chatPanel.contentView.centerXAnchor),
        label.centerYAnchor.constraint(equalTo: chatPanel.contentView.centerYAnchor)
      ])
    }

    input.placeholder = "コメント"
    input.textColor = .white
    input.backgroundColor = UIColor.white.withAlphaComponent(0.1)
    input.layer.cornerRadius = 14
    input.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
    input.leftViewMode = .always
    input.translatesAutoresizingMaskIntoConstraints = false
    addSubview(input)

    let send = UIButton(type: .system)
    send.setTitle("送信", for: .normal)
    send.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
    send.addAction(UIAction { [weak self] _ in self?.sendComment() }, for: .touchUpInside)
    send.translatesAutoresizingMaskIntoConstraints = false
    addSubview(send)

    var constraints: [NSLayoutConstraint] = [
      video.topAnchor.constraint(equalTo: topAnchor),
      video.leadingAnchor.constraint(equalTo: leadingAnchor),
      video.trailingAnchor.constraint(equalTo: trailingAnchor),
      video.bottomAnchor.constraint(equalTo: bottomAnchor),
      remove.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      remove.widthAnchor.constraint(equalToConstant: 36),
      remove.heightAnchor.constraint(equalToConstant: 36),
      volume.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      volume.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -80),
      volume.widthAnchor.constraint(equalToConstant: 42),
      volume.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.42),
      chatPanel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      chatPanel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      chatPanel.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -8),
      chatPanel.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.38),
      input.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      input.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      input.heightAnchor.constraint(equalToConstant: 40),
      send.leadingAnchor.constraint(equalTo: input.trailingAnchor, constant: 8),
      send.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      send.centerYAnchor.constraint(equalTo: input.centerYAnchor),
      send.widthAnchor.constraint(equalToConstant: 54)
    ]
    if let closeButton {
      constraints += [
        closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 10),
        closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
        closeButton.widthAnchor.constraint(equalToConstant: 36),
        closeButton.heightAnchor.constraint(equalToConstant: 36)
      ]
    }
    if let chatWeb {
      constraints += [
        chatWeb.topAnchor.constraint(equalTo: chatPanel.contentView.topAnchor),
        chatWeb.leadingAnchor.constraint(equalTo: chatPanel.contentView.leadingAnchor),
        chatWeb.trailingAnchor.constraint(equalTo: chatPanel.contentView.trailingAnchor),
        chatWeb.bottomAnchor.constraint(equalTo: chatPanel.contentView.bottomAnchor)
      ]
    }
    NSLayoutConstraint.activate(constraints)
    var autoHideControls: [UIView] = [remove, volume]
    if let closeButton {
      autoHideControls.append(closeButton)
    }
    autoHider = AutoHidingControls(host: self, controls: autoHideControls)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func sendComment() {
    guard let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
    if stream.platform == .kick, KickAuthManager.shared.isSignedIn {
      KickAuthManager.shared.sendChat(channel: stream.channel, content: text) { [weak self] result in
        DispatchQueue.main.async {
          switch result {
          case .success:
            self?.input.text = ""
          case .failure:
            self?.sendWebComment(text)
          }
        }
      }
      return
    }
    sendWebComment(text)
  }

  private func sendWebComment(_ text: String) {
    guard let chatWeb else { return }
    let escaped = text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'")
      .replacingOccurrences(of: "\n", with: " ")
    let script = """
    (function(){
      var el = document.querySelector('textarea, input[type=text], [contenteditable=true]');
      if (!el) return false;
      el.focus();
      if ('value' in el) {
        el.value = '\(escaped)';
        el.dispatchEvent(new Event('input', {bubbles:true}));
      } else {
        el.textContent = '\(escaped)';
        el.dispatchEvent(new InputEvent('input', {bubbles:true, data:'\(escaped)'}));
      }
      var submit = document.querySelector('button[type=submit], input[type=submit], button[aria-label*="Send"], button[aria-label*="送信"]');
      if (submit) submit.click();
      return true;
    })();
    """
    chatWeb.evaluateJavaScript(script)
    input.text = ""
  }

  private static func chatURL(for stream: StreamItem) -> URL? {
    let channel = stream.channel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stream.channel
    switch stream.platform {
    case .twitch:
      return URL(string: "https://www.twitch.tv/popout/\(channel)/chat?popout=")
    case .youtube:
      return URL(string: "https://www.youtube.com/live_chat?v=\(channel)&embed_domain=tonton888115.github.io")
    case .kick:
      return URL(string: "https://kick.com/\(channel)")
    case .twitcasting:
      return URL(string: "https://twitcasting.tv/\(channel)")
    case .niconico:
      return URL(string: "https://live.nicovideo.jp/watch/\(channel)")
    }
  }
}

final class RankingController: BrowserSourceController {
  private let allSources: [StreamPlatform: Source] = [
    .kick: Source(label: "Kick", url: URL(string: "https://ikioi-ranking.com/v/kick")!, host: "ikioi-ranking.com"),
    .twitch: Source(label: "Twitch", url: URL(string: "https://ikioi-ranking.com/v/twitch")!, host: "ikioi-ranking.com"),
    .youtube: Source(label: "YouTube", url: URL(string: "https://ikioi-ranking.com/v/youtube")!, host: "ikioi-ranking.com"),
    .niconico: Source(label: "ニコ生", url: URL(string: "https://ikioi-ranking.com/category/nico_user")!, host: "ikioi-ranking.com"),
    .twitcasting: Source(label: "ツイキャス", url: URL(string: "https://ikioi-ranking.com/v/twitcasting")!, host: "ikioi-ranking.com")
  ]

  override func sources() -> [(StreamPlatform, Source)] {
    AppState.shared.settings.platformOrder.compactMap { platform in
      allSources[platform].map { (platform, $0) }
    }
  }
}

final class FollowingController: BrowserSourceController {
  private let allSources: [StreamPlatform: Source] = [
    .twitch: Source(label: "Twitch", url: URL(string: "https://m.twitch.tv/directory/following")!, host: "twitch.tv"),
    .youtube: Source(label: "YouTube", url: URL(string: "https://m.youtube.com/feed/subscriptions")!, host: "youtube.com"),
    .kick: Source(label: "Kick", url: URL(string: "https://kick.com/following")!, host: "kick.com"),
    .niconico: Source(label: "ニコ生", url: URL(string: "https://live.nicovideo.jp/follow")!, host: "live.nicovideo.jp"),
    .twitcasting: Source(label: "ツイキャス", url: URL(string: "https://twitcasting.tv/")!, host: "twitcasting.tv")
  ]

  override func sources() -> [(StreamPlatform, Source)] {
    AppState.shared.settings.platformOrder.compactMap { platform in
      allSources[platform].map { (platform, $0) }
    }
  }
}

struct Source {
  let label: String
  let url: URL
  let host: String
}

class BrowserSourceController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
  private let segmented = UISegmentedControl()
  private let web: WKWebView = {
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    config.websiteDataStore = .default()
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    return WKWebView(frame: .zero, configuration: config)
  }()
  private var activeSources = [(StreamPlatform, Source)]()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)
    web.navigationDelegate = self
    web.uiDelegate = self
    installStreamURLBridge()
    web.allowsBackForwardNavigationGestures = true
    segmented.addTarget(self, action: #selector(sourceChanged), for: .valueChanged)
    segmented.translatesAutoresizingMaskIntoConstraints = false
    web.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(segmented)
    view.addSubview(web)
    NSLayoutConstraint.activate([
      segmented.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      segmented.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
      segmented.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
      web.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
      web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      web.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
    reloadOrder()
  }

  deinit {
    web.configuration.userContentController.removeScriptMessageHandler(forName: "streamURL")
  }

  func sources() -> [(StreamPlatform, Source)] { [] }

  func reloadOrder() {
    guard isViewLoaded else { return }
    activeSources = sources()
    segmented.removeAllSegments()
    activeSources.enumerated().forEach { index, item in
      segmented.insertSegment(withTitle: item.1.label, at: index, animated: false)
    }
    segmented.selectedSegmentIndex = min(max(segmented.selectedSegmentIndex, 0), activeSources.count - 1)
    if segmented.selectedSegmentIndex == UISegmentedControl.noSegment, !activeSources.isEmpty {
      segmented.selectedSegmentIndex = 0
    }
    loadSelected()
  }

  @objc private func sourceChanged() {
    loadSelected()
  }

  private func loadSelected() {
    guard activeSources.indices.contains(segmented.selectedSegmentIndex) else { return }
    web.load(URLRequest(url: activeSources[segmented.selectedSegmentIndex].1.url))
  }

  private func installStreamURLBridge() {
    let source = """
    (function(){
      if (window.__multiViewURLBridge) return;
      window.__multiViewURLBridge = true;
      var last = '';
      function notify(url) {
        try {
          var value = String(url || location.href || '');
          if (!value || value === last) return;
          last = value;
          window.webkit.messageHandlers.streamURL.postMessage(value);
        } catch (e) {}
      }
      function notifySoon(url) {
        setTimeout(function(){ notify(url); notify(location.href); }, 80);
        setTimeout(function(){ notify(location.href); }, 500);
      }
      document.addEventListener('click', function(event) {
        var node = event.target;
        while (node && node !== document && !(node.tagName && node.tagName.toLowerCase() === 'a')) node = node.parentNode;
        if (node && node.href) notifySoon(node.href);
      }, true);
      ['pushState', 'replaceState'].forEach(function(name) {
        var original = history[name];
        history[name] = function() {
          var result = original.apply(this, arguments);
          notifySoon(location.href);
          return result;
        };
      });
      window.addEventListener('popstate', function(){ notifySoon(location.href); });
      setInterval(function(){ notify(location.href); }, 1200);
      notify(location.href);
    })();
    """
    let controller = web.configuration.userContentController
    controller.add(self, name: "streamURL")
    controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if let url = navigationAction.request.url, navigationAction.targetFrame?.isMainFrame != false, let parsed = parseStream(url) {
      addParsedStream(parsed)
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if let url = webView.url, let parsed = parseStream(url) {
      addParsedStream(parsed)
      return
    }
    webView.evaluateJavaScript("location.href") { [weak self] value, _ in
      guard let raw = value as? String, let url = URL(string: raw), let parsed = self?.parseStream(url) else { return }
      self?.addParsedStream(parsed)
    }
  }

  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else {
      return nil
    }
    if let parsed = parseStream(url) {
      addParsedStream(parsed)
      return nil
    }
    webView.load(navigationAction.request)
    return nil
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == "streamURL",
          let raw = message.body as? String,
          let url = URL(string: raw),
          let parsed = parseStream(url) else { return }
    addParsedStream(parsed)
  }

  private func addParsedStream(_ parsed: (StreamPlatform, String)) {
    AppState.shared.add(platform: parsed.0, channel: parsed.1)
    tabBarController?.selectedIndex = 2
    PlaybackCoordinator.shared.resumeAll()
  }

  private func parseStream(_ url: URL) -> (StreamPlatform, String)? {
    let host = url.host?.replacingOccurrences(of: "www.", with: "").lowercased() ?? ""
    let parts = url.path.split(separator: "/").map(String.init)
    if host == "live-info.soraweb.net",
       let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
      if let link = items.first(where: { $0.name == "link" })?.value,
         let linkedURL = URL(string: link),
         let parsed = parseStream(linkedURL) {
        return parsed
      }
      if let site = items.first(where: { $0.name == "site" })?.value,
         site == "nico",
         let liveNo = items.first(where: { $0.name == "liveNo" })?.value {
        return (.niconico, liveNo.hasPrefix("lv") ? liveNo : "lv\(liveNo)")
      }
    }
    if host == "kick.com", let first = parts.first, !["browse", "following", "search", "categories"].contains(first) {
      return (.kick, first)
    }
    if host == "twitch.tv" || host == "m.twitch.tv", let first = parts.first, !["directory", "videos"].contains(first) {
      return (.twitch, first)
    }
    if host.contains("youtube.com"), let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
      return (.youtube, v)
    }
    if host == "youtu.be", let first = parts.first {
      return (.youtube, first)
    }
    if host.contains("live.nicovideo.jp"), parts.count >= 2, parts[0] == "watch" {
      return (.niconico, parts.dropFirst().joined(separator: "/"))
    }
    if host == "twitcasting.tv", let first = parts.first, first != "search" {
      return (.twitcasting, first)
    }
    return nil
  }
}

final class SettingsController: UITableViewController {
  private var platforms: [StreamPlatform] { AppState.shared.settings.platformOrder }

  override func viewDidLoad() {
    super.viewDidLoad()
    tableView.backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)
    tableView.separatorColor = UIColor.white.withAlphaComponent(0.12)
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
  }

  func reload() {
    guard isViewLoaded else { return }
    tableView.reloadData()
  }

  override func numberOfSections(in tableView: UITableView) -> Int { 4 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch section {
    case 0: return 11
    case 1: return platforms.count
    case 2: return 3
    default: return 1
    }
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    switch section {
    case 0: return "視聴"
    case 1: return "サービス順"
    case 2: return "Kick OAuth"
    default: return "追加"
    }
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
    cell.backgroundColor = UIColor.white.withAlphaComponent(0.06)
    cell.textLabel?.textColor = .white
    cell.selectionStyle = .none
    cell.accessoryView = nil
    cell.accessoryType = .none

    if indexPath.section == 0 && indexPath.row == 0 {
      cell.textLabel?.text = "縦スクロール表示"
      let control = UISegmentedControl(items: ["縦", "グリッド"])
      control.selectedSegmentIndex = AppState.shared.settings.layoutMode == .stacked ? 0 : 1
      control.addAction(UIAction { action in
        guard let c = action.sender as? UISegmentedControl else { return }
        var settings = AppState.shared.settings
        settings.layoutMode = c.selectedSegmentIndex == 0 ? .stacked : .grid
        AppState.shared.settings = settings
      }, for: .valueChanged)
      cell.accessoryView = control
    } else if indexPath.section == 0 && indexPath.row == 1 {
      cell.textLabel?.text = "音声を有効にして開始"
      let toggle = UISwitch()
      toggle.isOn = AppState.shared.settings.playAudio
      toggle.addAction(UIAction { action in
        guard let s = action.sender as? UISwitch else { return }
        var settings = AppState.shared.settings
        settings.playAudio = s.isOn
        AppState.shared.settings = settings
      }, for: .valueChanged)
      cell.accessoryView = toggle
    } else if indexPath.section == 0 && indexPath.row == 2 {
      cell.textLabel?.text = "弾幕を表示"
      let toggle = UISwitch()
      toggle.isOn = AppState.shared.settings.showChat
      toggle.addAction(UIAction { action in
        guard let s = action.sender as? UISwitch else { return }
        var settings = AppState.shared.settings
        settings.showChat = s.isOn
        AppState.shared.settings = settings
      }, for: .valueChanged)
      cell.accessoryView = toggle
    } else if indexPath.section == 0 && indexPath.row == 3 {
      cell.textLabel?.text = "Wi-Fi時の画質"
      cell.accessoryView = qualityControl(selected: AppState.shared.settings.wifiQuality) { quality in
        var settings = AppState.shared.settings
        settings.wifiQuality = quality
        AppState.shared.settings = settings
      }
    } else if indexPath.section == 0 && indexPath.row == 4 {
      cell.textLabel?.text = "モバイル通信時の画質"
      cell.accessoryView = qualityControl(selected: AppState.shared.settings.mobileQuality) { quality in
        var settings = AppState.shared.settings
        settings.mobileQuality = quality
        AppState.shared.settings = settings
      }
    } else if indexPath.section == 0 && indexPath.row == 5 {
      cell.textLabel?.text = "CORSプロキシ"
      cell.detailTextLabel?.text = nil
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    } else if indexPath.section == 0 {
      cell.textLabel?.text = danmakuTitle(row: indexPath.row)
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    } else if indexPath.section == 1 {
      let platform = platforms[indexPath.row]
      cell.textLabel?.text = platform.label
      let control = UISegmentedControl(items: ["↑", "↓"])
      control.frame = CGRect(x: 0, y: 0, width: 82, height: 30)
      control.setEnabled(indexPath.row > 0, forSegmentAt: 0)
      control.setEnabled(indexPath.row < platforms.count - 1, forSegmentAt: 1)
      control.addAction(UIAction { [weak self] action in
        guard let control = action.sender as? UISegmentedControl else { return }
        self?.movePlatform(at: indexPath.row, direction: control.selectedSegmentIndex == 0 ? -1 : 1)
        control.selectedSegmentIndex = UISegmentedControl.noSegment
      }, for: .valueChanged)
      cell.accessoryView = control
    } else if indexPath.section == 2 {
      let config = KickAuthManager.shared.config
      switch indexPath.row {
      case 0:
        cell.textLabel?.text = KickAuthManager.shared.isSignedIn ? "Kickログアウト" : "Kick OAuthログイン"
      case 1:
        cell.textLabel?.text = config.clientId.isEmpty ? "Client ID 未設定" : "Client ID 設定済み"
      default:
        cell.textLabel?.text = "Redirect URI \(config.redirectURI)"
      }
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    } else {
      cell.textLabel?.text = "配信を手動追加"
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    }
    return cell
  }

  override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
    false
  }

  override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
    .none
  }

  override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
    false
  }

  override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
    guard sourceIndexPath.section == 1, destinationIndexPath.section == 1 else { return }
    var settings = AppState.shared.settings
    let moved = settings.platformOrder.remove(at: sourceIndexPath.row)
    settings.platformOrder.insert(moved, at: destinationIndexPath.row)
    AppState.shared.settings = settings
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    if indexPath.section == 0 && indexPath.row == 5 {
      editProxy()
    } else if indexPath.section == 0 && (6...10).contains(indexPath.row) {
      editDanmakuValue(row: indexPath.row)
    } else if indexPath.section == 2 {
      handleKickOAuthRow(indexPath.row)
    } else if indexPath.section == 3 {
      present(AddStreamController(), animated: true)
    }
  }

  private func danmakuTitle(row: Int) -> String {
    let settings = AppState.shared.settings
    switch row {
    case 6:
      return "文字サイズ \(Int(settings.danmakuFontSize))"
    case 7:
      return "速度 \(Int((settings.danmakuSpeed / 0.13) * 100))%"
    case 8:
      return "透過度 \(Int(settings.danmakuOpacity * 100))%"
    case 9:
      return "最大行数 \(settings.danmakuMaxLines == 0 ? "自動" : String(settings.danmakuMaxLines))"
    case 10:
      return "最大文字数 \(settings.danmakuMaxLength == 0 ? "無制限" : String(settings.danmakuMaxLength))"
    default:
      return ""
    }
  }

  private func qualityControl(selected: PlaybackQuality, onChange: @escaping (PlaybackQuality) -> Void) -> UISegmentedControl {
    let control = UISegmentedControl(items: [PlaybackQuality.high.label, PlaybackQuality.economy.label])
    control.selectedSegmentIndex = selected == .high ? 0 : 1
    control.addAction(UIAction { action in
      guard let control = action.sender as? UISegmentedControl else { return }
      onChange(control.selectedSegmentIndex == 0 ? .high : .economy)
    }, for: .valueChanged)
    return control
  }

  private func editDanmakuValue(row: Int) {
    let settings = AppState.shared.settings
    let current: String
    let title: String
    let message: String
    switch row {
    case 6:
      title = "文字サイズ"
      current = String(Int(settings.danmakuFontSize))
      message = "12〜40"
    case 7:
      title = "速度"
      current = String(Int((settings.danmakuSpeed / 0.13) * 100))
      message = "100が標準"
    case 8:
      title = "透過度"
      current = String(Int(settings.danmakuOpacity * 100))
      message = "30〜100"
    case 9:
      title = "最大行数"
      current = String(settings.danmakuMaxLines)
      message = "0で自動"
    case 10:
      title = "最大文字数"
      current = String(settings.danmakuMaxLength)
      message = "0で無制限"
    default:
      return
    }

    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addTextField { field in
      field.text = current
      field.keyboardType = .numberPad
      field.clearButtonMode = .whileEditing
    }
    alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
    alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
      guard let raw = alert.textFields?.first?.text, let value = Double(raw) else { return }
      var settings = AppState.shared.settings
      switch row {
      case 6:
        settings.danmakuFontSize = min(40, max(12, value.rounded()))
      case 7:
        settings.danmakuSpeed = min(300, max(20, value)) / 100 * 0.13
      case 8:
        settings.danmakuOpacity = min(100, max(30, value)) / 100
      case 9:
        settings.danmakuMaxLines = min(20, max(0, Int(value.rounded())))
      case 10:
        settings.danmakuMaxLength = min(500, max(0, Int(value.rounded())))
      default:
        return
      }
      AppState.shared.settings = settings
      self?.tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .automatic)
    })
    present(alert, animated: true)
  }

  private func movePlatform(at index: Int, direction: Int) {
    let destination = index + direction
    guard platforms.indices.contains(index), platforms.indices.contains(destination) else { return }
    var settings = AppState.shared.settings
    let moved = settings.platformOrder.remove(at: index)
    settings.platformOrder.insert(moved, at: destination)
    AppState.shared.settings = settings
    tableView.reloadSections(IndexSet(integer: 1), with: .automatic)
  }

  private func editProxy() {
    let alert = UIAlertController(title: "CORSプロキシ", message: "Kick / ツイキャスの弾幕取得に使います", preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = "https://xxx.workers.dev/?url="
      field.text = AppState.shared.settings.proxyUrl
      field.keyboardType = .URL
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
    }
    alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
    alert.addAction(UIAlertAction(title: "保存", style: .default) { _ in
      var settings = AppState.shared.settings
      settings.proxyUrl = alert.textFields?.first?.text ?? ""
      AppState.shared.settings = settings
    })
    present(alert, animated: true)
  }

  private func handleKickOAuthRow(_ row: Int) {
    switch row {
    case 0:
      if KickAuthManager.shared.isSignedIn {
        KickAuthManager.shared.signOut()
        tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
        return
      }
      KickAuthManager.shared.signIn(presentationAnchor: view.window) { [weak self] result in
        DispatchQueue.main.async {
          self?.tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
          if case .failure(let error) = result {
            self?.presentError(error)
          }
        }
      }
    case 1:
      editKickClientID()
    case 2:
      editKickRedirectURI()
    default:
      break
    }
  }

  private func editKickClientID() {
    var config = KickAuthManager.shared.config
    let alert = UIAlertController(title: "Kick Client ID", message: nil, preferredStyle: .alert)
    alert.addTextField { field in
      field.text = config.clientId
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
    }
    alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
    alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
      config.clientId = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      KickAuthManager.shared.config = config
      self?.tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
    })
    present(alert, animated: true)
  }

  private func editKickRedirectURI() {
    var config = KickAuthManager.shared.config
    let alert = UIAlertController(title: "Kick Redirect URI", message: nil, preferredStyle: .alert)
    alert.addTextField { field in
      field.text = config.redirectURI
      field.keyboardType = .URL
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
    }
    alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
    alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
      config.redirectURI = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      KickAuthManager.shared.config = config
      self?.tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
    })
    present(alert, animated: true)
  }

  private func presentError(_ error: Error) {
    let alert = UIAlertController(title: "エラー", message: error.localizedDescription, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}

final class AddStreamController: UIViewController {
  private let segmented = UISegmentedControl()
  private let field = UITextField()
  private var selectedPlatform: StreamPlatform {
    let order = AppState.shared.settings.platformOrder
    guard order.indices.contains(segmented.selectedSegmentIndex) else { return .kick }
    return order[segmented.selectedSegmentIndex]
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)

    let close = UIButton(type: .system)
    close.setTitle("閉じる", for: .normal)
    close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
    close.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(close)

    let order = AppState.shared.settings.platformOrder
    order.enumerated().forEach { index, platform in
      segmented.insertSegment(withTitle: platform.label, at: index, animated: false)
    }
    segmented.selectedSegmentIndex = 0
    segmented.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(segmented)

    field.placeholder = selectedPlatform.hint
    field.textColor = .white
    field.backgroundColor = UIColor.white.withAlphaComponent(0.1)
    field.layer.cornerRadius = 12
    field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
    field.leftViewMode = .always
    field.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(field)

    let add = UIButton(type: .system)
    add.setTitle("追加", for: .normal)
    add.titleLabel?.font = .systemFont(ofSize: 17, weight: .bold)
    add.addAction(UIAction { [weak self] _ in self?.submit() }, for: .touchUpInside)
    add.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(add)

    NSLayoutConstraint.activate([
      close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
      segmented.topAnchor.constraint(equalTo: close.bottomAnchor, constant: 20),
      segmented.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
      segmented.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
      field.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 18),
      field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
      field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
      field.heightAnchor.constraint(equalToConstant: 44),
      add.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 18),
      add.centerXAnchor.constraint(equalTo: view.centerXAnchor)
    ])
  }

  private func submit() {
    guard let text = field.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    AppState.shared.add(platform: selectedPlatform, channel: text)
    dismiss(animated: true)
  }
}
