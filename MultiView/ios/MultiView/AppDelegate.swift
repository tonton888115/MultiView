import UIKit
import WebKit
import AVFoundation
import Network
import ImageIO

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  // Set when another app/video interrupts our audio session. When we regain
  // control we rebuild the players (auto-refresh) instead of only nudging play,
  // because embedded players often stay paused after a takeover.
  private var needsPlaybackReload = false

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
    // Pull any fresh web-view logins into the native cookie jar.
    WebLoginCookies.sync()
    if needsPlaybackReload {
      needsPlaybackReload = false
      reloadAndResumeSoon()
    } else {
      resumePlaybackSoon()
    }
  }

  // No audio-session work when leaving the foreground: re-activating while another
  // app is taking over would fight it (and stop the other source). The session
  // stays active for background audio until iOS interrupts us, and we only reclaim
  // it when we come back (applicationDidBecomeActive) or the interruption ends.

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
            let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
      switch type {
      case .began:
        // Another app grabbed the audio session. YIELD: explicitly pause every
        // player (AVPlayer auto-pauses, but WKWebView media may not) and do NOT
        // reactivate the session — that fight was stopping the other app's audio.
        PlaybackCoordinator.shared.pauseAll()
        needsPlaybackReload = true
      case .ended:
        // Standard system flow (same as Music): resume only when iOS sets
        // shouldResume. This avoids relying on applicationState, which is
        // unreliable under LiveContainer, so we never re-grab while another app
        // is still meant to own audio. (If shouldResume is absent, we recover when
        // the user returns to us via applicationDidBecomeActive.)
        let shouldResume = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
          .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
        if shouldResume {
          needsPlaybackReload = false
          configureAudioSession()
          reloadAndResumeSoon()
        }
      @unknown default:
        break
      }
      return
    }
    // Route change (headphones, etc.) — only nudge while frontmost.
    if UIApplication.shared.applicationState == .active {
      configureAudioSession()
      resumePlaybackSoon()
    }
  }

  private func resumePlaybackSoon() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      PlaybackCoordinator.shared.resumeAll()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
      PlaybackCoordinator.shared.resumeAll()
    }
  }

  private func reloadAndResumeSoon() {
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .multiViewReloadAndResume, object: nil)
    }
    resumePlaybackSoon()
  }
}

protocol PlaybackResumable: AnyObject {
  func resumePlayback()
  func pausePlayback()
}

extension PlaybackResumable {
  func pausePlayback() {}
}

protocol PlaybackStoppable: AnyObject {
  func stopPlayback()
}

protocol AudioControllable: AnyObject {
  func setPlaybackVolume(_ volume: Float)
}

// A player that can post a chat comment for its own stream (using the logged-in
// session it already holds), so a cell can send without leaving the grid.
protocol CommentPostable: AnyObject {
  func postComment(_ text: String, completion: @escaping (Result<Void, Error>) -> Void)
}

final class AutoHidingControls: NSObject, UIGestureRecognizerDelegate {
  private weak var host: UIView?
  private let controls: [UIView]
  private var hideWorkItem: DispatchWorkItem?

  init(host: UIView, controls: [UIView]) {
    self.host = host
    self.controls = controls
    super.init()
    let tap = UITapGestureRecognizer(target: self, action: #selector(showTemporarily))
    tap.delegate = self
    tap.cancelsTouchesInView = false
    tap.delaysTouchesBegan = false
    tap.delaysTouchesEnded = false
    host.addGestureRecognizer(tap)
    showTemporarily()
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    true
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

  func pauseAll() {
    for object in views.allObjects {
      (object as? PlaybackResumable)?.pausePlayback()
    }
  }
}

// Liquid Glass (iOS 26) adoption with a material-blur fallback. The
// `#if compiler(>=6.2)` guard keeps the iOS 26-only symbols out of older SDKs
// (Xcode < 26) so the project still builds, while `#available` picks the right
// path at runtime.
enum LiquidGlass {
  static func makePanel(
    cornerRadius: CGFloat,
    interactive: Bool = false,
    fallbackStyle: UIBlurEffect.Style = .systemUltraThinMaterialDark
  ) -> UIVisualEffectView {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = interactive
      let view = UIVisualEffectView(effect: glass)
      view.layer.cornerRadius = cornerRadius
      view.clipsToBounds = true
      return view
    }
    #endif
    let view = UIVisualEffectView(effect: UIBlurEffect(style: fallbackStyle))
    view.layer.cornerRadius = cornerRadius
    view.clipsToBounds = true
    return view
  }

  // Builds a capsule button that uses a glass configuration on iOS 26 and a
  // tinted/gray configuration on older systems. `tint` is used as the accent for
  // prominent buttons (e.g. play); pass nil for a neutral button.
  static func makeButton(title: String?, systemImage: String?, tint: UIColor?) -> UIButton {
    let button = UIButton(type: .system)
    var config: UIButton.Configuration
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      config = tint != nil ? .prominentGlass() : .glass()
    } else {
      config = legacyConfiguration(tint: tint)
    }
    #else
    config = legacyConfiguration(tint: tint)
    #endif
    if let title { config.title = title }
    if let systemImage { config.image = UIImage(systemName: systemImage) }
    config.imagePadding = 6
    config.cornerStyle = .capsule
    config.baseForegroundColor = .white
    if let tint { config.baseBackgroundColor = tint }
    config.contentInsets = title == nil
      ? NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
      : NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 16)
    button.configuration = config
    button.tintColor = .white
    return button
  }

  private static func legacyConfiguration(tint: UIColor?) -> UIButton.Configuration {
    if let tint {
      var config = UIButton.Configuration.filled()
      config.baseBackgroundColor = tint.withAlphaComponent(0.85)
      return config
    }
    var config = UIButton.Configuration.gray()
    config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.16)
    return config
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
    // All platforms now have a dedicated per-cell native player.
    true
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
  var autoFollowRaids = false
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
    autoFollowRaids = try container.decodeIfPresent(Bool.self, forKey: .autoFollowRaids) ?? false
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
  private var lastOnCellular: Bool?
  private var lastChangeAt = Date.distantPast

  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      self?.queue.async {
        self?.currentPath = path
        self?.detectConnectionChange(path)
      }
    }
    monitor.start(queue: queue)
  }

  // Tell the app when the connection flips WiFi<->cellular so it can re-pick the
  // quality for already-playing streams (activeQuality is otherwise only read when
  // a player is created). Debounced to real transitions.
  private func detectConnectionChange(_ path: NWPath) {
    guard path.status == .satisfied else { return }
    let onCellular = path.usesInterfaceType(.cellular) || path.isExpensive
    defer { lastOnCellular = onCellular }
    guard let previous = lastOnCellular, previous != onCellular else { return }
    guard Date().timeIntervalSince(lastChangeAt) > 4 else { return }
    lastChangeAt = Date()
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .multiViewNetworkQualityChanged, object: nil)
    }
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

// Copies the logins made in the in-app web views (WKWebsiteDataStore) into the
// shared HTTPCookieStorage that the native URLSession players use. WKWebView and
// URLSession keep separate cookie jars, so without this a fresh web login is not
// seen by the native fetch until much later (the "permission error until reload"
// the user hit). Run it proactively so native playback uses the latest session.
enum WebLoginCookies {
  private static let domains = ["nicovideo.jp", "kick.com", "twitch.tv", "twitcasting.tv", "youtube.com", "google.com"]

  static func sync(_ completion: (() -> Void)? = nil) {
    let store = WKWebsiteDataStore.default().httpCookieStore
    store.getAllCookies { cookies in
      for cookie in cookies where domains.contains(where: { cookie.domain.contains($0) }) {
        HTTPCookieStorage.shared.setCookie(cookie)
      }
      DispatchQueue.main.async { completion?() }
    }
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

extension Notification.Name {
  static let multiViewRaidFollowed = Notification.Name("MultiViewRaidFollowed")
  // Posted when audio was taken over by another app/video and control returned,
  // so the viewing tab rebuilds its players (auto-refresh) and resumes playback.
  static let multiViewReloadAndResume = Notification.Name("MultiViewReloadAndResume")
  // Posted when the connection flips WiFi<->cellular so the viewing tab can rebuild
  // players at the quality for the new network.
  static let multiViewNetworkQualityChanged = Notification.Name("MultiViewNetworkQualityChanged")
  // Posted by a player when it hits a recoverable error so the viewing tab can
  // auto-refresh (debounced) to clear it.
  static let multiViewPlaybackErrored = Notification.Name("MultiViewPlaybackErrored")
}

enum RaidAutoFollow {
  static func follow(platform: StreamPlatform, channel rawChannel: String, currentChannel: String) {
    let channel = normalize(rawChannel, platform: platform)
    let current = normalize(currentChannel, platform: platform)
    guard !channel.isEmpty, channel.lowercased() != current.lowercased() else { return }
    DispatchQueue.main.async {
      guard AppState.shared.settings.autoFollowRaids else { return }
      if AppState.shared.addIfNeeded(platform: platform, channel: channel) {
        NotificationCenter.default.post(name: .multiViewRaidFollowed, object: nil)
      }
    }
  }

  static func detectTarget(in text: String, preferredPlatform: StreamPlatform) -> (StreamPlatform, String)? {
    let lower = text.lowercased()
    guard lower.contains("raid") || lower.contains("raiding") || lower.contains("レイド") || lower.contains("host") || lower.contains("hosting") || lower.contains("ホスト") else {
      return nil
    }
    if let linked = firstStreamURL(in: text) {
      return linked
    }
    return plainMentionTarget(in: text, preferredPlatform: preferredPlatform)
  }

  static func detectTarget(in payload: Any, preferredPlatform: StreamPlatform) -> (StreamPlatform, String)? {
    if let text = payload as? String {
      return detectTarget(in: text, preferredPlatform: preferredPlatform)
    }
    if let dict = payload as? [String: Any] {
      if let direct = targetFromDictionary(dict, preferredPlatform: preferredPlatform) {
        return direct
      }
      let joined = dict.compactMap { key, value -> String? in
        guard key.lowercased().contains("raid") || key.lowercased().contains("host") || key.lowercased().contains("target") else { return nil }
        return "\(key) \(value)"
      }.joined(separator: " ")
      if let direct = detectTarget(in: joined, preferredPlatform: preferredPlatform) {
        return direct
      }
      for value in dict.values {
        if let nested = detectTarget(in: value, preferredPlatform: preferredPlatform) {
          return nested
        }
      }
    }
    if let array = payload as? [Any] {
      for value in array {
        if let nested = detectTarget(in: value, preferredPlatform: preferredPlatform) {
          return nested
        }
      }
    }
    return nil
  }

  private static func targetFromDictionary(_ dict: [String: Any], preferredPlatform: StreamPlatform) -> (StreamPlatform, String)? {
    for (key, value) in dict {
      let lowerKey = key.lowercased()
      guard lowerKey.contains("target") || lowerKey == "to" || lowerKey.contains("recipient") || lowerKey.contains("raided") || lowerKey.contains("hosted") else {
        continue
      }
      if let text = value as? String {
        if let linked = firstStreamURL(in: text) {
          return linked
        }
        let channel = normalize(text, platform: preferredPlatform)
        if !channel.isEmpty {
          return (preferredPlatform, channel)
        }
      }
      if let nested = detectTarget(in: value, preferredPlatform: preferredPlatform) {
        return nested
      }
    }
    return nil
  }

  private static func firstStreamURL(in text: String) -> (StreamPlatform, String)? {
    let pattern = #"https?://[^\s<>"']+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    for match in regex.matches(in: text, range: range) {
      guard let valueRange = Range(match.range, in: text),
            let url = URL(string: String(text[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,)」]"))) else { continue }
      let host = url.host?.replacingOccurrences(of: "www.", with: "").lowercased() ?? ""
      let parts = url.path.split(separator: "/").map(String.init)
      if (host == "twitch.tv" || host == "m.twitch.tv"), let first = parts.first {
        let channel = normalize(first, platform: .twitch)
        if !channel.isEmpty { return (.twitch, channel) }
      }
      if host == "kick.com", let first = parts.first {
        let channel = normalize(first, platform: .kick)
        if !channel.isEmpty { return (.kick, channel) }
      }
    }
    return nil
  }

  private static func plainMentionTarget(in text: String, preferredPlatform: StreamPlatform) -> (StreamPlatform, String)? {
    let pattern = #"(?:raid(?:ing)?|レイド|host(?:ing)?|ホスト)[^\w@#]{0,24}@?([A-Za-z0-9_.-]{2,32})"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          let valueRange = Range(match.range(at: 1), in: text) else { return nil }
    let channel = normalize(String(text[valueRange]), platform: preferredPlatform)
    let ignored = ["to", "into", "over", "the", "a", "channel", "チャンネル"]
    guard !ignored.contains(channel.lowercased()) else { return nil }
    return channel.isEmpty ? nil : (preferredPlatform, channel)
  }

  private static func normalize(_ raw: String, platform: StreamPlatform) -> String {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    value = value.replacingOccurrences(of: "^[@#]+", with: "", options: .regularExpression)
    if let range = value.range(of: "twitch.tv/", options: .caseInsensitive) {
      value = String(value[range.upperBound...])
    }
    if let range = value.range(of: "kick.com/", options: .caseInsensitive) {
      value = String(value[range.upperBound...])
    }
    value = value.components(separatedBy: CharacterSet(charactersIn: "/?# \n\t.,)」]")).first ?? value
    switch platform {
    case .twitch:
      return value.lowercased()
    case .kick:
      return value
    default:
      return value
    }
  }
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
    _ = addIfNeeded(platform: platform, channel: rawChannel)
  }

  @discardableResult
  func addIfNeeded(platform: StreamPlatform, channel rawChannel: String) -> Bool {
    let channel = rawChannel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !channel.isEmpty else { return false }
    if streams.contains(where: { $0.platform == platform && $0.channel.lowercased() == channel.lowercased() }) {
      return false
    }
    // A stream is usually added straight after logging in / browsing in a web view,
    // so capture that session for the native player about to be created.
    WebLoginCookies.sync()
    streams.append(StreamItem(id: UUID().uuidString, platform: platform, channel: channel))
    return true
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
    tabBar.tintColor = .systemBlue
    // On iOS 26 the tab bar is Liquid Glass automatically; overriding its
    // background would fight that, so only style it on older systems.
    var useNativeGlassBar = false
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) { useNativeGlassBar = true }
    #endif
    if !useNativeGlassBar {
      tabBar.isTranslucent = true
      tabBar.standardAppearance = glassTabAppearance()
      if #available(iOS 15.0, *) {
        tabBar.scrollEdgeAppearance = tabBar.standardAppearance
      }
    }

    followingVC.tabBarItem = UITabBarItem(title: "フォロー", image: UIImage(systemName: "antenna.radiowaves.left.and.right"), selectedImage: UIImage(systemName: "antenna.radiowaves.left.and.right.fill"))
    rankingVC.tabBarItem = UITabBarItem(title: "ランキング", image: UIImage(systemName: "chart.bar"), selectedImage: UIImage(systemName: "chart.bar.fill"))
    viewVC.tabBarItem = UITabBarItem(title: "視聴", image: UIImage(systemName: "square.grid.2x2"), selectedImage: UIImage(systemName: "square.grid.2x2.fill"))
    settingsVC.tabBarItem = UITabBarItem(title: "設定", image: UIImage(systemName: "gearshape"), selectedImage: UIImage(systemName: "gearshape.fill"))
    viewControllers = [followingVC, rankingVC, viewVC, settingsVC]
    selectedIndex = 2
    NotificationCenter.default.addObserver(self, selector: #selector(raidFollowed), name: .multiViewRaidFollowed, object: nil)
  }

  func appStateDidChange() {
    viewVC.reload()
    rankingVC.reloadOrder()
    followingVC.reloadOrder()
    settingsVC.reload()
  }

  @objc private func raidFollowed() {
    selectedIndex = 2
    viewVC.reload()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      PlaybackCoordinator.shared.resumeAll()
    }
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
    syncWebViewCookies { [weak self] in
      self?.fetchLatestMovie()
    }
  }

  private func fetchLatestMovie() {
    guard !stopped, !channel.isEmpty else { return }
    guard let encoded = channel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          let url = URL(string: "https://frontendapi.twitcasting.tv/users/\(encoded)/latest-movie") else { return }
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://twitcasting.tv/\(encoded)", forHTTPHeaderField: "Referer")
    if let cookie = Self.cookieHeader() {
      request.setValue(cookie, forHTTPHeaderField: "Cookie")
    }
    URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
      guard let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let movie = json["movie"] as? [String: Any],
            let movieId = Self.stringValue(movie["id"]) else {
        DispatchQueue.main.async { self?.fetchMovieIDFromWatchPage() }
        return
      }
      DispatchQueue.main.async { self?.fetchSubscribeURL(movieId: movieId) }
    }.resume()
  }

  private func fetchMovieIDFromWatchPage() {
    guard !stopped, !channel.isEmpty else { return }
    guard let encoded = channel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          let url = URL(string: "https://twitcasting.tv/\(encoded)") else { return }
    var request = URLRequest(url: url)
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://twitcasting.tv/", forHTTPHeaderField: "Referer")
    if let cookie = Self.cookieHeader() {
      request.setValue(cookie, forHTTPHeaderField: "Cookie")
    }
    URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
      guard let self else { return }
      guard let data,
            let html = String(data: data, encoding: .utf8),
            let movieId = Self.parseMovieID(from: html) else {
        DispatchQueue.main.async { self.scheduleRetry() }
        return
      }
      DispatchQueue.main.async { self.fetchSubscribeURL(movieId: movieId) }
    }.resume()
  }

  private func fetchSubscribeURL(movieId: String) {
    guard !stopped, let url = URL(string: "https://twitcasting.tv/eventpubsuburl.php") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://twitcasting.tv/\(channel)", forHTTPHeaderField: "Referer")
    request.setValue("https://twitcasting.tv", forHTTPHeaderField: "Origin")
    request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
    if let cookie = Self.cookieHeader() {
      request.setValue(cookie, forHTTPHeaderField: "Cookie")
    }
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
          let json = try? JSONSerialization.jsonObject(with: data) else { return }
    for item in Self.commentItems(from: json) {
      guard let message = item["message"] as? String, !message.isEmpty else { continue }
      let author = (item["author"] as? [String: Any])?["name"] as? String
        ?? (item["user"] as? [String: Any])?["name"] as? String
        ?? ""
      onComment(message, author)
    }
  }

  private static func commentItems(from value: Any) -> [[String: Any]] {
    if let array = value as? [Any] {
      return array.flatMap { commentItems(from: $0) }
    }
    guard let dict = value as? [String: Any] else { return [] }
    let type = (dict["type"] as? String) ?? (dict["event"] as? String) ?? ""
    if let message = dict["message"] as? String, !message.isEmpty,
       (type.isEmpty || type.localizedCaseInsensitiveContains("comment") || dict["author"] != nil || dict["user"] != nil) {
      return [dict]
    }
    if let message = dict["message"] as? [String: Any] {
      return commentItems(from: message)
    }
    if let data = dict["data"] {
      return commentItems(from: data)
    }
    if let payload = dict["payload"] {
      return commentItems(from: payload)
    }
    return []
  }

  private static func parseMovieID(from html: String) -> String? {
    let patterns = [
      #""movie_id"\s*:\s*"?(\d+)"?"#,
      #""movieId"\s*:\s*"?(\d+)"?"#,
      #"data-movie-id=["'](\d+)["']"#,
      #"/movie/(\d+)"#
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: html) else { continue }
      return String(html[range])
    }
    return nil
  }

  private static func stringValue(_ value: Any?) -> String? {
    if let s = value as? String { return s }
    if let i = value as? Int { return String(i) }
    if let n = value as? NSNumber { return n.stringValue }
    return nil
  }

  private func syncWebViewCookies(_ completion: @escaping () -> Void) {
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
      cookies
        .filter { $0.domain.contains("twitcasting.tv") }
        .forEach { HTTPCookieStorage.shared.setCookie($0) }
      DispatchQueue.main.async(execute: completion)
    }
  }

  private static func cookieHeader() -> String? {
    let urls = [
      URL(string: "https://twitcasting.tv/"),
      URL(string: "https://frontendapi.twitcasting.tv/")
    ].compactMap { $0 }
    let cookies = urls.flatMap { HTTPCookieStorage.shared.cookies(for: $0) ?? [] }
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

  private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
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
      if #available(iOS 13.0, *) {
        config.defaultWebpagePreferences.preferredContentMode = .mobile
      }
      config.userContentController.addUserScript(WKUserScript(source: PlayerWebView.niconicoPopupBlockerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }
    super.init(frame: .zero, configuration: config)
    isOpaque = false
    backgroundColor = .black
    scrollView.backgroundColor = .black
    scrollView.contentInsetAdjustmentBehavior = .never
    if stream.platform == .niconico {
      customUserAgent = Self.mobileSafariUserAgent
    }
    navigationDelegate = self
    PlaybackCoordinator.shared.register(self)
    load(stream: stream, settings: settings)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func load(stream: StreamItem, settings: AppSettings) {
    if stream.platform == .niconico {
      var request = URLRequest(url: URL(string: "https://live.nicovideo.jp/watch/\(stream.channel)")!)
      Self.mobileBrowserHeaders(referer: "https://live.nicovideo.jp/").forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
      load(request)
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

  func pausePlayback() {
    guard !isStopped else { return }
    evaluateJavaScript("""
    (function(){
      document.querySelectorAll('video,audio').forEach(function(m){ try { m.pause(); } catch(e) {} });
      document.querySelectorAll('iframe').forEach(function(f){
        try { f.contentWindow.postMessage({type:'pause'}, '*'); } catch(e) {}
        try { f.contentWindow.postMessage(JSON.stringify({event:'command',func:'pauseVideo',args:[]}), '*'); } catch(e) {}
      });
    })();
    """)
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

  private static let mobileSafariUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"

  private static func mobileBrowserHeaders(referer: String) -> [String: String] {
    [
      "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6",
      "User-Agent": mobileSafariUserAgent,
      "Referer": referer
    ]
  }

}

private enum NativeDanmakuToken {
  case text(String)
  case image(URL)
}

private final class NativeDanmakuRenderer {
  private static let imageCache = NSCache<NSURL, UIImage>()

  static func emit(
    tokens: [NativeDanmakuToken],
    filterText: String,
    in root: UIView,
    laneCursor: Int,
    settings: AppSettings
  ) -> Int {
    let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return laneCursor }
    if settings.danmakuMaxLength > 0, trimmed.count > settings.danmakuMaxLength {
      return laneCursor
    }
    guard root.bounds.height > 0, root.bounds.width > 0 else { return laneCursor }

    let fontSize = scaledFontSize(base: settings.danmakuFontSize, in: root)
    let lineHeight = fontSize + 8
    let maxLines = settings.danmakuMaxLines > 0
      ? settings.danmakuMaxLines
      : max(1, Int(root.bounds.height / lineHeight))
    let lane = laneCursor % maxLines
    let comment = makeCommentView(tokens: tokens, fontSize: fontSize, opacity: settings.danmakuOpacity, lineHeight: lineHeight)
    guard comment.bounds.width > 0 else { return laneCursor }

    let y = CGFloat(lane) * lineHeight + 6
    let startX = root.bounds.width + 12
    comment.frame.origin = CGPoint(x: startX, y: y)
    root.addSubview(comment)

    let travel = startX + comment.bounds.width + 24
    let pixelsPerSecond = max(35, root.bounds.width * CGFloat(settings.danmakuSpeed))
    let duration = TimeInterval(travel / pixelsPerSecond)
    UIView.animate(withDuration: duration, delay: 0, options: [.curveLinear]) {
      comment.frame.origin.x = -comment.bounds.width - 12
    } completion: { _ in
      comment.removeFromSuperview()
    }
    return laneCursor + 1
  }

  static func textTokens(_ text: String) -> [NativeDanmakuToken] {
    [.text(text)]
  }

  // Scale the configured comment size to the cell so text keeps a consistent
  // proportion: bigger in a single-column (wide) cell, smaller in a packed grid
  // (narrow) cell. Reference width ~= a phone single-column cell.
  static func scaledFontSize(base: Double, in view: UIView) -> CGFloat {
    let referenceWidth: CGFloat = 340
    let width = view.bounds.width
    guard width > 0 else { return CGFloat(base) }
    let scale = min(1.8, max(0.55, width / referenceWidth))
    return (CGFloat(base) * scale).rounded()
  }

  private static func makeCommentView(
    tokens: [NativeDanmakuToken],
    fontSize: CGFloat,
    opacity: Double,
    lineHeight: CGFloat
  ) -> UIView {
    let container = UIView()
    var x: CGFloat = 0
    let imageSide = max(18, fontSize * 1.4)

    for token in tokens {
      switch token {
      case .text(let text):
        guard !text.isEmpty else { continue }
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: fontSize, weight: .bold)
        label.textColor = UIColor.white.withAlphaComponent(CGFloat(opacity))
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowRadius = 2
        label.layer.shadowOpacity = 1
        label.layer.shadowOffset = CGSize(width: 1, height: 1)
        label.sizeToFit()
        label.frame.origin = CGPoint(x: x, y: 0)
        container.addSubview(label)
        x += label.bounds.width
      case .image(let url):
        let imageView = UIImageView(frame: CGRect(x: x + 3, y: max(0, (lineHeight - imageSide) / 2), width: imageSide, height: imageSide))
        imageView.contentMode = .scaleAspectFit
        imageView.alpha = CGFloat(opacity)
        imageView.layer.shadowColor = UIColor.black.cgColor
        imageView.layer.shadowRadius = 2
        imageView.layer.shadowOpacity = 1
        imageView.layer.shadowOffset = CGSize(width: 1, height: 1)
        container.addSubview(imageView)
        loadImage(url, into: imageView)
        x += imageSide + 6
      }
    }

    container.frame = CGRect(x: 0, y: 0, width: x, height: lineHeight)
    return container
  }

  private static func loadImage(_ url: URL, into imageView: UIImageView) {
    let key = url as NSURL
    if let cached = imageCache.object(forKey: key) {
      imageView.image = cached
      if cached.images?.isEmpty == false {
        imageView.startAnimating()
      }
      return
    }
    URLSession.shared.dataTask(with: url) { data, _, _ in
      guard let data, let image = animatedImage(from: data) ?? UIImage(data: data) else { return }
      imageCache.setObject(image, forKey: key)
      DispatchQueue.main.async {
        imageView.image = image
        if image.images?.isEmpty == false {
          imageView.startAnimating()
        }
      }
    }.resume()
  }

  private static func animatedImage(from data: Data) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let count = CGImageSourceGetCount(source)
    guard count > 1 else { return nil }

    var images: [UIImage] = []
    var duration: TimeInterval = 0
    for index in 0..<count {
      guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
      images.append(UIImage(cgImage: cgImage))
      duration += frameDuration(at: index, source: source)
    }
    guard !images.isEmpty else { return nil }
    return UIImage.animatedImage(with: images, duration: max(duration, Double(images.count) * 0.08))
  }

  private static func frameDuration(at index: Int, source: CGImageSource) -> TimeInterval {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
          let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
      return 0.1
    }
    let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
    let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
    let value = unclamped ?? clamped ?? 0.1
    return value < 0.02 ? 0.1 : value
  }
}

final class NiconicoNativePlayerView: UIView, PlaybackResumable, PlaybackStoppable, AudioControllable, CommentPostable {
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
  private var loadAttempts = 0
  private var streamOpenedAt: Date?

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
    guard !programId.isEmpty,
          let url = URL(string: "https://api.cas.nicovideo.jp/v1/services/live/programs/\(programId)/comments") else {
      completion(.failure(NSError(domain: "Niconico", code: -1, userInfo: [NSLocalizedDescriptionKey: "番組IDが不正です"])))
      return
    }
    guard let cookieURL = URL(string: "https://live.nicovideo.jp/"),
          let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL),
          cookies.contains(where: { $0.name == "user_session" }) else {
      completion(.failure(NSError(domain: "Niconico", code: 401, userInfo: [NSLocalizedDescriptionKey: "ニコ生にログインしてください"])))
      return
    }
    let elapsed = streamOpenedAt.map { Date().timeIntervalSince($0) } ?? 0
    let vpos = max(0, Int(elapsed * 100))
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://live.nicovideo.jp/watch/\(programId)", forHTTPHeaderField: "Referer")
    request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["message": text, "command": "184", "vpos": String(vpos)])
    URLSession.shared.dataTask(with: request) { _, response, error in
      DispatchQueue.main.async {
        if let error {
          completion(.failure(error))
          return
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
          completion(.failure(NSError(domain: "Niconico", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "投稿失敗 (HTTP \(http.statusCode))"])))
          return
        }
        completion(.success(()))
      }
    }.resume()
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
    syncNiconicoWebCookies { [weak self] in
      self?.fetchWatchPage(url: url)
    }
  }

  // The first attempt right after a web login often runs before the login cookies
  // have propagated to the native jar, so transient failures retry the whole load
  // (re-syncing cookies) a couple of times before giving up to the web fallback —
  // this removes the "expand once and come back" workaround.
  private func retryOrFallback(_ reason: String) {
    guard !isStopped, fallbackWebView == nil else { return }
    loadAttempts += 1
    guard loadAttempts <= 2 else {
      installFallback(reason)
      return
    }
    showStatus("ニコ生再試行中… (\(loadAttempts))")
    socketTask?.cancel(with: .goingAway, reason: nil)
    socketTask = nil
    isLoading = false
    let delay = Double(loadAttempts)
    WebLoginCookies.sync { [weak self] in
      guard let self, !self.isStopped else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        self.load(channel: self.channel)
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
        let watch = try self.parseWatchData(from: html)
        self.connect(webSocketURL: watch.webSocketURL, frontendId: watch.frontendId)
      } catch {
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
      loadAttempts = 0
      if streamOpenedAt == nil { streamOpenedAt = Date() }
      let cookies = parseStreamCookies(payload["cookies"], for: uri)
      applyNiconicoCookies(cookies)
      play(hlsURL: uri, cookies: cookies)
    }
    if type == "error",
       let payload = json["data"] as? [String: Any],
       let code = payload["code"] as? String {
      showStatus("ニコ生エラー: \(code)")
      if code.lowercased().contains("permission") || code.lowercased().contains("resource") {
        // Usually a just-completed web login whose cookies have not reached the
        // native jar yet — re-sync and retry the whole load before falling back.
        retryOrFallback("ニコ生エラー: \(code)")
      }
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
    var headers = Self.mobileBrowserHeaders(referer: watchPageURL?.absoluteString ?? "https://live.nicovideo.jp/")
    headers["Origin"] = "https://live.nicovideo.jp"
    let cookieURL = URL(string: "https://live.nicovideo.jp/")!
    if let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL), !cookies.isEmpty {
      headers["Cookie"] = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    return headers
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
        .filter { $0.domain.contains("nicovideo.jp") }
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
    ndgrCommentTask = Task { [weak self] in
      guard let self else { return }
      await self.streamNDGRView(viewURI: viewURI)
    }
  }

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
        consecutiveFailures = 0
      } catch {
        if Task.isCancelled || error is CancellationError {
          return
        }
        consecutiveFailures += 1
        nextAt = requestAt ?? "now"
        showStatus("ニコ生コメント取得失敗: \(error.localizedDescription)")
        if consecutiveFailures >= 3 {
          // The comment view URI has likely gone stale; rather than retry a dead
          // endpoint forever, request a full auto-refresh to get a fresh session.
          DispatchQueue.main.async {
            NotificationCenter.default.post(name: .multiViewPlaybackErrored, object: nil)
          }
          return
        }
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
      let fontSize = NativeDanmakuRenderer.scaledFontSize(base: self.settings.danmakuFontSize, in: self.danmakuView)
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

final class KickNativePlayerView: UIView, PlaybackResumable, PlaybackStoppable, AudioControllable, CommentPostable {
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
    // Auto-follow a raid/host ONLY from Kick's explicit host events, matched by
    // their exact class names (from the official app: StreamHostEvent /
    // StreamHostedEvent / ChatMoveToSupportedChannelEvent). Chat text is never
    // scanned for keywords — that caused false jumps on ordinary messages.
    if event.contains("ChatMoveToSupportedChannel")
      || event.contains("StreamHostEvent")
      || event.contains("StreamHostedEvent") {
      // `hosted`/destination is the channel being hosted: the raid target when our
      // channel raids out, or our own channel on an incoming host (which
      // RaidAutoFollow.follow ignores — so an incoming host never makes us jump).
      if settings.autoFollowRaids, let target = Self.kickHostTarget(in: payload) {
        RaidAutoFollow.follow(platform: .kick, channel: target, currentChannel: stream.channel)
      }
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

  // The channel being hosted/raided-to, taken from the official Kick host-event
  // payload shapes: StreamHostEvent has a `hosted` object; the chat-move event has
  // a destination `channel` object. `host_username` (the source) is intentionally
  // ignored. Never scans free text, so it cannot pick up a wrong channel name.
  private static func kickHostTarget(in payload: [String: Any]) -> String? {
    for key in ["hosted", "channel"] {
      if let nested = payload[key] as? [String: Any],
         let slug = (nested["slug"] as? String) ?? (nested["username"] as? String), !slug.isEmpty {
        return slug
      }
      if let slug = payload[key] as? String, !slug.isEmpty {
        return slug
      }
    }
    if let slug = payload["slug"] as? String, !slug.isEmpty {
      return slug
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

  func pausePlayback() {
    player.pause()
    fallbackWebView?.pausePlayback()
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

final class TwitcastingNativePlayerView: UIView, PlaybackResumable, PlaybackStoppable, AudioControllable {
  private let stream: StreamItem
  private let settings: AppSettings
  private let player = AVPlayer()
  private let playerLayer = AVPlayerLayer()
  private let danmakuView = UIView()
  private let statusLabel = UILabel()
  private var chatClient: TwitcastingChatClient?
  private var streamTask: URLSessionDataTask?
  private var itemStatusObservation: NSKeyValueObservation?
  private var itemFailedObserver: NSObjectProtocol?
  private var fallbackWebView: WKWebView?
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

  func stopPlayback() {
    isStopped = true
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
  }

  private func loadNativeStream() {
    guard !isStopped, !isLoading, fallbackWebView == nil else { return }
    isLoading = true
    showStatus("ツイキャスをネイティブ再生で読み込み中")
    syncTwitcastingWebCookies { [weak self] in
      self?.fetchStreamServer()
    }
  }

  private func fetchStreamServer() {
    guard !isStopped else { return }
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
      // Keep isLoading true until play()/installEmbedFallback runs on the main
      // queue, so a concurrent resumePlayback() can't kick off a second fetch.
      if let error {
        self.installEmbedFallback("ツイキャス取得失敗: \(error.localizedDescription)")
        return
      }
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        self.installEmbedFallback("ツイキャス取得失敗: HTTP \(http.statusCode)")
        return
      }
      guard let data, let info = Self.extractStreamInfo(from: data) else {
        self.installEmbedFallback("ツイキャスの配信情報を取得できません")
        return
      }
      guard let hlsURL = info.hlsURL else {
        self.installEmbedFallback(info.isLive ? "ツイキャスのHLSを取得できません" : "ツイキャスはオフラインです")
        return
      }
      // Play the HLS whenever one is advertised. If it is stale (truly offline)
      // AVPlayer fails and we drop to the official embed.
      self.play(hlsURL: hlsURL)
    }
    streamTask?.resume()
  }

  private func play(hlsURL: URL) {
    DispatchQueue.main.async {
      self.isLoading = false
      guard !self.isStopped else { return }
      self.statusLabel.isHidden = true
      var options: [String: Any] = [
        "AVURLAssetHTTPHeaderFieldsKey": self.twitcastingPlaybackHeaders()
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
      item.preferredPeakBitRate = NetworkQuality.shared.activeQuality(settings: self.settings).preferredPeakBitRate
      self.itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
        if item.status == .failed {
          DispatchQueue.main.async {
            self?.installEmbedFallback(item.error?.localizedDescription ?? "ツイキャスのネイティブ再生に失敗しました")
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
        self?.installEmbedFallback(error?.localizedDescription ?? "ツイキャスのネイティブ再生が停止しました")
      }
      self.player.replaceCurrentItem(with: item)
      self.player.isMuted = !self.settings.playAudio
      self.player.volume = self.settings.playAudio ? self.playbackVolume : 0
      self.player.play()
    }
  }

  // Last resort: the official embedded player (handles offline/standby and
  // member-only lives that the native HLS path cannot reach).
  private func installEmbedFallback(_ reason: String) {
    DispatchQueue.main.async {
      self.isLoading = false
      guard !self.isStopped, self.fallbackWebView == nil else { return }
      self.showStatus(reason)
      self.player.pause()
      self.player.replaceCurrentItem(with: nil)
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

// Per-cell YouTube player using the IFrame Player API, so YouTube behaves like the
// other individual native players (video + audio). It autoplays muted (the only
// autoplay browsers allow) and then unmutes via the API — which works without a
// user gesture because the web view disables the user-action playback requirement.
final class YouTubeNativePlayerView: UIView, PlaybackResumable, PlaybackStoppable, AudioControllable {
  private let stream: StreamItem
  private let settings: AppSettings
  private let web: WKWebView
  private var playbackVolume: Float
  private var isStopped = false

  init(stream: StreamItem, settings: AppSettings) {
    self.stream = stream
    self.settings = settings
    self.playbackVolume = StreamVolumeStore.volume(for: stream)
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    config.websiteDataStore = .default()
    self.web = WKWebView(frame: .zero, configuration: config)
    super.init(frame: .zero)
    backgroundColor = .black
    web.isOpaque = false
    web.backgroundColor = .black
    web.scrollView.backgroundColor = .black
    web.scrollView.isScrollEnabled = false
    web.scrollView.contentInsetAdjustmentBehavior = .never
    web.translatesAutoresizingMaskIntoConstraints = false
    addSubview(web)
    NSLayoutConstraint.activate([
      web.topAnchor.constraint(equalTo: topAnchor),
      web.leadingAnchor.constraint(equalTo: leadingAnchor),
      web.trailingAnchor.constraint(equalTo: trailingAnchor),
      web.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
    PlaybackCoordinator.shared.register(self)
    loadPlayer()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    stopPlayback()
  }

  func resumePlayback() {
    guard !isStopped else { return }
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default, options: [])
    try? session.setActive(true)
    web.evaluateJavaScript("window.mvPlay && window.mvPlay();")
  }

  func pausePlayback() {
    guard !isStopped else { return }
    web.evaluateJavaScript("window.mvPause && window.mvPause();")
  }

  func setPlaybackVolume(_ volume: Float) {
    playbackVolume = min(1, max(0, volume))
    let on = settings.playAudio ? playbackVolume : 0
    web.evaluateJavaScript("window.mvVolume && window.mvVolume(\(on));")
  }

  func stopPlayback() {
    isStopped = true
    web.evaluateJavaScript("window.mvPause && window.mvPause();")
    web.stopLoading()
    web.loadHTMLString("", baseURL: nil)
  }

  private func loadPlayer() {
    let videoId = stream.channel.trimmingCharacters(in: .whitespacesAndNewlines)
      .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    let audioOn = settings.playAudio && playbackVolume > 0
    let volume = Int((settings.playAudio ? playbackVolume : 0) * 100)
    // A real HTTPS base URL on our own domain gives the embed a valid origin/Referer
    // (loadHTMLString with youtube.com or nil triggers YouTube error 152).
    web.loadHTMLString(Self.html(videoId: videoId, audioOn: audioOn, volume: volume), baseURL: URL(string: "https://tonton888115.github.io/MultiView/"))
  }

  private static func html(videoId: String, audioOn: Bool, volume: Int) -> String {
    """
    <!doctype html>
    <html>
    <head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#p{position:absolute;inset:0}</style></head>
    <body>
    <div id="p"></div>
    <script src="https://www.youtube.com/iframe_api"></script>
    <script>
      var player, READY=false, VID="\(videoId)", AUDIO=\(audioOn ? "true" : "false"), VOL=\(volume);
      function onYouTubeIframeAPIReady(){
        player=new YT.Player('p',{videoId:VID,host:'https://www.youtube.com',
          playerVars:{autoplay:1,mute:1,playsinline:1,controls:1,rel:0,modestbranding:1,origin:'https://tonton888115.github.io'},
          events:{onReady:function(){READY=true;apply();},
          onStateChange:function(e){ if(e.data===YT.PlayerState.UNSTARTED||e.data===YT.PlayerState.CUED){ try{e.target.playVideo();}catch(x){} } }}});
      }
      function apply(){ if(!player||!READY)return; try{ player.playVideo(); if(AUDIO){player.unMute();player.setVolume(VOL);} else {player.mute();} }catch(x){} }
      window.mvPlay=function(){ apply(); };
      window.mvPause=function(){ try{ player&&player.pauseVideo(); }catch(x){} };
      window.mvVolume=function(v){ VOL=Math.round(Math.max(0,Math.min(1,v))*100); AUDIO=VOL>0; apply(); };
    </script>
    </body>
    </html>
    """
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

  func pausePlayback() {
    guard !isStopped else { return }
    evaluateJavaScript("""
    (function(){
      document.querySelectorAll('video,audio').forEach(function(m){ try { m.pause(); } catch(e) {} });
      document.querySelectorAll('iframe').forEach(function(f){
        try { f.contentWindow.postMessage({type:'pause'}, '*'); } catch(e) {}
        try { f.contentWindow.postMessage(JSON.stringify({event:'command',func:'pauseVideo',args:[]}), '*'); } catch(e) {}
      });
    })();
    """)
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
  private weak var dragSourceCell: StreamCellView?
  private weak var dragTargetCell: StreamCellView?
  private var dragSnapshot: UIView?
  private var dragSourceStream: StreamItem?
  private var lastAutoReloadAt = Date.distantPast

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)
    configureScroll()
    reload()
    NotificationCenter.default.addObserver(self, selector: #selector(reloadAndResume), name: .multiViewReloadAndResume, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(networkQualityChanged), name: .multiViewNetworkQualityChanged, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(playbackErrored), name: .multiViewPlaybackErrored, object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func reloadAndResume() {
    reload()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      PlaybackCoordinator.shared.resumeAll()
    }
  }

  @objc private func networkQualityChanged() {
    // Rebuild players at the new network's quality — but only when the two profiles
    // actually differ, otherwise the switch would change nothing.
    let settings = AppState.shared.settings
    guard settings.wifiQuality != settings.mobileQuality else { return }
    reloadAndResume()
  }

  @objc private func playbackErrored() {
    // Debounced auto-refresh to clear a recoverable error. Capped at once per 45s
    // and coalesced so a permanently-failing stream can't trigger a reload loop.
    guard Date().timeIntervalSince(lastAutoReloadAt) > 45 else { return }
    lastAutoReloadAt = Date()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      self?.reloadAndResume()
    }
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

  private func makeCell(_ stream: StreamItem) -> StreamCellView {
    StreamCellView(stream: stream, onFocus: { [weak self] in
      self?.focused = stream
      self?.reload()
    }, onReorder: { [weak self] cell, gesture in
      self?.handleReorder(cell: cell, gesture: gesture)
    })
  }

  private func addStackedCell(_ stream: StreamItem) {
    let cell = makeCell(stream)
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

    // Clear segmented toggle: the selected side (縦 / グリッド) is highlighted.
    let layoutControl = UISegmentedControl(items: [
      UIImage(systemName: "rectangle.grid.1x2") ?? UIImage(),
      UIImage(systemName: "square.grid.2x2") ?? UIImage()
    ])
    layoutControl.selectedSegmentIndex = AppState.shared.settings.layoutMode == .stacked ? 0 : 1
    layoutControl.selectedSegmentTintColor = .systemBlue
    layoutControl.setImage(UIImage(systemName: "rectangle.grid.1x2"), forSegmentAt: 0)
    layoutControl.setImage(UIImage(systemName: "square.grid.2x2"), forSegmentAt: 1)
    layoutControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
    layoutControl.translatesAutoresizingMaskIntoConstraints = false
    layoutControl.addAction(UIAction { [weak self] actionEvent in
      guard let control = actionEvent.sender as? UISegmentedControl else { return }
      var settings = AppState.shared.settings
      settings.layoutMode = control.selectedSegmentIndex == 0 ? .stacked : .grid
      AppState.shared.settings = settings
      self?.reload()
    }, for: .valueChanged)

    let spacer = UIView()
    spacer.translatesAutoresizingMaskIntoConstraints = false

    let playButton = playbackButton(title: "全て再生", icon: "play.fill", color: UIColor(red: 0.20, green: 0.80, blue: 0.45, alpha: 1)) {
      PlaybackCoordinator.shared.resumeAll()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        PlaybackCoordinator.shared.resumeAll()
      }
    }
    let reloadButton = playbackButton(title: "更新", icon: "arrow.triangle.2.circlepath", color: nil) { [weak self] in
      self?.reload()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        PlaybackCoordinator.shared.resumeAll()
      }
    }
    row.addArrangedSubview(layoutControl)
    row.addArrangedSubview(spacer)
    row.addArrangedSubview(playButton)
    row.addArrangedSubview(reloadButton)

    stack.addArrangedSubview(host)
    NSLayoutConstraint.activate([
      host.heightAnchor.constraint(equalToConstant: 40),
      row.centerYAnchor.constraint(equalTo: host.centerYAnchor),
      row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      layoutControl.widthAnchor.constraint(equalToConstant: 96),
      layoutControl.heightAnchor.constraint(equalToConstant: 34),
      playButton.heightAnchor.constraint(equalToConstant: 36),
      reloadButton.heightAnchor.constraint(equalToConstant: 36)
    ])
  }

  private func playbackButton(title: String, icon: String, color: UIColor?, action: @escaping () -> Void) -> UIButton {
    let button = LiquidGlass.makeButton(title: title, systemImage: icon, tint: color)
    button.addAction(UIAction { actionEvent in
      guard let sender = actionEvent.sender as? UIButton else {
        action()
        return
      }
      let originalTitle = sender.configuration?.title
      sender.alpha = 0.62
      sender.configuration?.title = "実行中"
      action()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        sender.alpha = 1
        sender.configuration?.title = originalTitle
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
    // Full pairs go two-up; a trailing odd stream gets its own full-width row so no
    // empty space is left beside it.
    var index = 0
    while index + 2 <= streams.count {
      let row = UIStackView()
      row.axis = .horizontal
      row.spacing = 10
      row.distribution = .fillEqually
      row.addArrangedSubview(makeCell(streams[index]))
      row.addArrangedSubview(makeCell(streams[index + 1]))
      stack.addArrangedSubview(row)
      row.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 9 / 32).isActive = true
      row.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
      index += 2
    }
    if index < streams.count {
      addStackedCell(streams[index])
    }
  }

  private func handleReorder(cell: StreamCellView, gesture: UILongPressGestureRecognizer) {
    guard focused == nil, AppState.shared.streams.count > 1 else { return }
    let location = gesture.location(in: view)
    switch gesture.state {
    case .began:
      beginReorder(cell: cell, at: location)
    case .changed:
      updateReorder(at: location)
    case .ended:
      finishReorder(commit: true)
    case .cancelled, .failed:
      finishReorder(commit: false)
    default:
      break
    }
  }

  private func beginReorder(cell: StreamCellView, at location: CGPoint) {
    guard dragSnapshot == nil else { return }
    dragSourceCell = cell
    dragTargetCell = cell
    dragSourceStream = cell.stream
    scrollView.isScrollEnabled = false
    cell.setReorderSourceActive(true)
    let snapshot = cell.snapshotView(afterScreenUpdates: false) ?? UIView(frame: cell.bounds)
    snapshot.frame = cell.convert(cell.bounds, to: view)
    snapshot.layer.shadowColor = UIColor.black.cgColor
    snapshot.layer.shadowOpacity = 0.35
    snapshot.layer.shadowRadius = 14
    snapshot.layer.shadowOffset = CGSize(width: 0, height: 8)
    snapshot.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
    view.addSubview(snapshot)
    dragSnapshot = snapshot
    updateReorder(at: location)
  }

  private func updateReorder(at location: CGPoint) {
    dragSnapshot?.center = location
    guard let target = reorderCell(at: location), target !== dragSourceCell else {
      if dragTargetCell !== dragSourceCell {
        dragTargetCell?.setDropTargetActive(false)
        dragTargetCell = dragSourceCell
      }
      return
    }
    if target !== dragTargetCell {
      dragTargetCell?.setDropTargetActive(false)
      dragTargetCell = target
      target.setDropTargetActive(true)
    }
  }

  private func finishReorder(commit: Bool) {
    scrollView.isScrollEnabled = true
    let sourceCell = dragSourceCell
    let targetCell = dragTargetCell
    let sourceStream = dragSourceStream
    dragSourceCell = nil
    dragTargetCell = nil
    dragSourceStream = nil

    sourceCell?.setReorderSourceActive(false)
    targetCell?.setDropTargetActive(false)

    let snapshot = dragSnapshot
    dragSnapshot = nil
    UIView.animate(withDuration: 0.16, animations: {
      if let sourceCell, let snapshot {
        snapshot.frame = sourceCell.convert(sourceCell.bounds, to: self.view)
      }
      snapshot?.alpha = 0
    }, completion: { _ in
      snapshot?.removeFromSuperview()
    })

    guard commit,
          let sourceStream,
          let targetStream = targetCell?.stream,
          sourceStream.id != targetStream.id,
          let from = AppState.shared.streams.firstIndex(where: { $0.id == sourceStream.id }),
          let to = AppState.shared.streams.firstIndex(where: { $0.id == targetStream.id }) else { return }
    var next = AppState.shared.streams
    let moved = next.remove(at: from)
    let insertIndex = from < to ? to - 1 : to
    next.insert(moved, at: max(0, min(insertIndex, next.count)))
    AppState.shared.streams = next
  }

  private func reorderCell(at location: CGPoint) -> StreamCellView? {
    let cells = reorderCells(in: stack)
    if let containing = cells.first(where: { $0.convert($0.bounds, to: view).contains(location) }) {
      return containing
    }
    return cells.min { lhs, rhs in
      let left = lhs.convert(lhs.bounds, to: view).centerDistance(to: location)
      let right = rhs.convert(rhs.bounds, to: view).centerDistance(to: location)
      return left < right
    }
  }

  private func reorderCells(in root: UIView) -> [StreamCellView] {
    var result: [StreamCellView] = []
    for subview in root.subviews {
      if let cell = subview as? StreamCellView {
        result.append(cell)
      } else {
        result.append(contentsOf: reorderCells(in: subview))
      }
    }
    return result
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

private extension CGRect {
  func centerDistance(to point: CGPoint) -> CGFloat {
    hypot(midX - point.x, midY - point.y)
  }
}

final class StreamCellView: UIView, UIGestureRecognizerDelegate, UITextFieldDelegate {
  let stream: StreamItem
  private let onReorder: (StreamCellView, UILongPressGestureRecognizer) -> Void
  private var autoHider: AutoHidingControls?
  private let commentBar = UIView()
  private let commentField = UITextField()
  private let commentStatus = UILabel()
  private var commentBottom: NSLayoutConstraint?
  private weak var commentPoster: CommentPostable?

  init(stream: StreamItem, onFocus: @escaping () -> Void, onReorder: @escaping (StreamCellView, UILongPressGestureRecognizer) -> Void) {
    self.stream = stream
    self.onReorder = onReorder
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
    } else if stream.platform == .twitcasting {
      video = TwitcastingNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else if stream.platform == .youtube {
      video = YouTubeNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else {
      video = PlayerWebView(stream: stream, settings: AppState.shared.settings)
    }
    let audio = video as? AudioControllable
    commentPoster = video as? CommentPostable
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

    let comment = UIButton(type: .system)
    comment.setImage(UIImage(systemName: "text.bubble"), for: .normal)
    comment.tintColor = .white
    comment.backgroundColor = UIColor.black.withAlphaComponent(0.38)
    comment.layer.cornerRadius = 16
    comment.addAction(UIAction { [weak self] _ in self?.toggleCommentBar() }, for: .touchUpInside)
    comment.translatesAutoresizingMaskIntoConstraints = false
    addSubview(comment)

    buildCommentBar()

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
      comment.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      comment.trailingAnchor.constraint(equalTo: focus.leadingAnchor, constant: -8),
      comment.widthAnchor.constraint(equalToConstant: 32),
      comment.heightAnchor.constraint(equalToConstant: 32),
      volume.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      volume.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      volume.widthAnchor.constraint(equalToConstant: 42),
      volume.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.62)
    ])
    autoHider = AutoHidingControls(host: self, controls: [focus, remove, comment, volume])
    let reorder = UILongPressGestureRecognizer(target: self, action: #selector(handleReorderGesture(_:)))
    reorder.minimumPressDuration = 0.45
    reorder.delegate = self
    addGestureRecognizer(reorder)
  }

  private func buildCommentBar() {
    commentBar.translatesAutoresizingMaskIntoConstraints = false
    commentBar.backgroundColor = UIColor.black.withAlphaComponent(0.6)
    commentBar.isHidden = true
    addSubview(commentBar)

    commentStatus.font = .systemFont(ofSize: 11)
    commentStatus.textColor = UIColor.white.withAlphaComponent(0.85)
    commentStatus.numberOfLines = 1
    commentStatus.isHidden = true
    commentStatus.translatesAutoresizingMaskIntoConstraints = false
    commentBar.addSubview(commentStatus)

    commentField.placeholder = "コメント"
    commentField.font = .systemFont(ofSize: 13)
    commentField.textColor = .white
    commentField.backgroundColor = UIColor.white.withAlphaComponent(0.14)
    commentField.layer.cornerRadius = 8
    commentField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
    commentField.leftViewMode = .always
    commentField.returnKeyType = .send
    commentField.autocorrectionType = .no
    commentField.delegate = self
    commentField.translatesAutoresizingMaskIntoConstraints = false
    commentBar.addSubview(commentField)

    let send = UIButton(type: .system)
    send.setImage(UIImage(systemName: "paperplane.fill"), for: .normal)
    send.tintColor = .systemBlue
    send.addAction(UIAction { [weak self] _ in self?.submitComment() }, for: .touchUpInside)
    send.translatesAutoresizingMaskIntoConstraints = false
    commentBar.addSubview(send)

    let bottom = commentBar.bottomAnchor.constraint(equalTo: bottomAnchor)
    commentBottom = bottom
    NSLayoutConstraint.activate([
      commentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
      commentBar.trailingAnchor.constraint(equalTo: trailingAnchor),
      bottom,
      commentBar.heightAnchor.constraint(equalToConstant: 46),
      commentStatus.leadingAnchor.constraint(equalTo: commentBar.leadingAnchor, constant: 12),
      commentStatus.topAnchor.constraint(equalTo: commentBar.topAnchor, constant: 3),
      commentField.leadingAnchor.constraint(equalTo: commentBar.leadingAnchor, constant: 10),
      commentField.bottomAnchor.constraint(equalTo: commentBar.bottomAnchor, constant: -8),
      commentField.heightAnchor.constraint(equalToConstant: 30),
      send.leadingAnchor.constraint(equalTo: commentField.trailingAnchor, constant: 8),
      send.trailingAnchor.constraint(equalTo: commentBar.trailingAnchor, constant: -10),
      send.centerYAnchor.constraint(equalTo: commentField.centerYAnchor),
      send.widthAnchor.constraint(equalToConstant: 30)
    ])
    NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
  }

  @objc private func keyboardWillChange(_ note: Notification) {
    guard commentField.isFirstResponder,
          let window,
          let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
    let keyboardTop = value.cgRectValue.minY
    let cellInWindow = convert(bounds, to: window)
    let overlap = cellInWindow.maxY - keyboardTop
    commentBottom?.constant = overlap > 0 ? -overlap : 0
    UIView.animate(withDuration: 0.2) { self.superview?.layoutIfNeeded() }
  }

  @objc private func keyboardWillHide() {
    commentBottom?.constant = 0
    UIView.animate(withDuration: 0.2) { self.superview?.layoutIfNeeded() }
  }

  private func toggleCommentBar() {
    setCommentBar(visible: commentBar.isHidden)
  }

  private func setCommentBar(visible: Bool) {
    commentBar.isHidden = !visible
    if visible {
      commentField.becomeFirstResponder()
    } else {
      commentField.resignFirstResponder()
    }
  }

  private func submitComment() {
    let text = commentField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else { return }
    guard let poster = commentPoster else {
      // No native posting for this platform yet — the expanded view can post via
      // the logged-in chat web.
      showCommentStatus("拡大(⤢)してコメントを送信できます")
      return
    }
    showCommentStatus("送信中…")
    poster.postComment(text) { [weak self] result in
      switch result {
      case .success:
        self?.commentField.text = ""
        self?.showCommentStatus("送信しました")
        self?.setCommentBar(visible: false)
      case .failure(let error):
        self?.showCommentStatus(error.localizedDescription)
      }
    }
  }

  private func showCommentStatus(_ text: String) {
    commentStatus.text = text
    commentStatus.isHidden = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
      self?.commentStatus.isHidden = true
    }
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    submitComment()
    return true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func handleReorderGesture(_ gesture: UILongPressGestureRecognizer) {
    onReorder(self, gesture)
  }

  func setReorderSourceActive(_ active: Bool) {
    alpha = active ? 0.42 : 1
    layer.borderWidth = active ? 2 : 0.5
    layer.borderColor = (active ? UIColor.systemYellow : UIColor.white.withAlphaComponent(0.18)).cgColor
  }

  func setDropTargetActive(_ active: Bool) {
    guard dragVisualCanChange else { return }
    layer.borderWidth = active ? 2 : 0.5
    layer.borderColor = (active ? UIColor.systemGreen : UIColor.white.withAlphaComponent(0.18)).cgColor
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    var current: UIView? = touch.view
    while let view = current {
      if view is UIControl { return false }
      current = view.superview
    }
    return true
  }

  private var dragVisualCanChange: Bool {
    alpha > 0.8
  }
}

final class VolumeOverlay: UIVisualEffectView {
  init(stream: StreamItem, onChange: @escaping (Float) -> Void) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      super.init(effect: UIGlassEffect())
    } else {
      super.init(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    }
    #else
    super.init(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    #endif
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
    } else if stream.platform == .twitcasting {
      video = TwitcastingNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else if stream.platform == .youtube {
      video = YouTubeNativePlayerView(stream: stream, settings: AppState.shared.settings)
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

    let chatPanel = LiquidGlass.makePanel(cornerRadius: 18)
    chatPanel.translatesAutoresizingMaskIntoConstraints = false
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
      var lastGestureAt = 0;
      // Only treat a URL change as a stream selection when it follows a real user
      // tap. Auto-redirects (e.g. Twitch sending a logged-out user to a featured
      // channel) and periodic polling must NOT add streams or switch tabs.
      function recentGesture() { return (Date.now() - lastGestureAt) < 1500; }
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
      ['pointerdown', 'touchstart', 'mousedown'].forEach(function(name){
        document.addEventListener(name, function(){ lastGestureAt = Date.now(); }, true);
      });
      document.addEventListener('click', function(event) {
        lastGestureAt = Date.now();
        var node = event.target;
        while (node && node !== document && !(node.tagName && node.tagName.toLowerCase() === 'a')) node = node.parentNode;
        if (node && node.href) notifySoon(node.href);
      }, true);
      ['pushState', 'replaceState'].forEach(function(name) {
        var original = history[name];
        history[name] = function() {
          var result = original.apply(this, arguments);
          if (recentGesture()) notifySoon(location.href);
          return result;
        };
      });
      window.addEventListener('popstate', function(){ if (recentGesture()) notifySoon(location.href); });
    })();
    """
    let controller = web.configuration.userContentController
    controller.add(self, name: "streamURL")
    controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    // Only a user-activated link should add a stream and jump to the viewing tab.
    // Server/SPA redirects (navigationType .other) must navigate normally so that
    // opening the Following tab never auto-selects a featured channel.
    if navigationAction.navigationType == .linkActivated,
       let url = navigationAction.request.url,
       navigationAction.targetFrame?.isMainFrame != false,
       let parsed = parseStream(url) {
      addParsedStream(parsed)
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
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
    // Only a user-tapped link that opens a new window should add a stream;
    // programmatic window.open (navigationType .other) must not.
    if navigationAction.navigationType == .linkActivated, let parsed = parseStream(url) {
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
    if host == "kick.com", let first = parts.first, !Self.kickNonStreamPaths.contains(first) {
      return (.kick, first)
    }
    if host == "twitch.tv" || host == "m.twitch.tv", let first = parts.first, !Self.twitchNonStreamPaths.contains(first) {
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

  private static let kickNonStreamPaths: Set<String> = [
    "browse", "categories", "category", "following", "search", "clips", "about",
    "help", "dashboard", "messages", "settings", "subscriptions", "login",
    "signup", "auth", "oauth"
  ]

  private static let twitchNonStreamPaths: Set<String> = [
    "directory", "videos", "login", "signup", "p", "settings", "subscriptions",
    "wallet", "drops", "u", "downloads", "jobs", "privacy", "terms", "turbo",
    "store"
  ]
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

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    if section == 2 {
      return "Client IDはあなたのユーザーIDではなく、kick.com → Settings → Developer で作るOAuthアプリのIDです。そのアプリに Redirect URI「\(KickAuthManager.shared.config.redirectURI)」を登録してください(Redirect URI行をタップでコピー)。コメント投稿に使います。"
    }
    guard section == numberOfSections(in: tableView) - 1 else { return nil }
    let info = Bundle.main.infoDictionary
    let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
    let build = (info?["CFBundleVersion"] as? String) ?? "?"
    return "MultiView \(version) (build \(build))"
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
    cell.backgroundColor = UIColor.white.withAlphaComponent(0.06)
    cell.textLabel?.textColor = .white
    cell.selectionStyle = .none
    cell.accessoryView = nil
    cell.accessoryType = .none

    if indexPath.section == 0 && indexPath.row == 0 {
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
    } else if indexPath.section == 0 && indexPath.row == 1 {
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
    } else if indexPath.section == 0 && indexPath.row == 2 {
      cell.textLabel?.text = "レイド先を自動追加"
      let toggle = UISwitch()
      toggle.isOn = AppState.shared.settings.autoFollowRaids
      toggle.addAction(UIAction { action in
        guard let s = action.sender as? UISwitch else { return }
        var settings = AppState.shared.settings
        settings.autoFollowRaids = s.isOn
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
      let uri = KickAuthManager.shared.config.redirectURI
      UIPasteboard.general.string = uri
      let alert = UIAlertController(
        title: "Redirect URI をコピーしました",
        message: "\(uri)\n\nKickの開発者ポータル(Settings → Developer)で作成したアプリのRedirect URIに、この値をそのまま登録してください。",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "編集", style: .default) { [weak self] _ in self?.editKickRedirectURI() })
      alert.addAction(UIAlertAction(title: "OK", style: .cancel))
      present(alert, animated: true)
    default:
      break
    }
  }

  private func editKickClientID() {
    var config = KickAuthManager.shared.config
    let alert = UIAlertController(title: "Kick Client ID", message: "kick.com → Settings → Developer でOAuthアプリを作成し、表示される Client ID を貼り付けてください(ユーザーIDではありません)。", preferredStyle: .alert)
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
