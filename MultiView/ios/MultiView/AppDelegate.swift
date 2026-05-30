import UIKit
import WebKit
import AVFoundation
import Network
import ImageIO
import AuthenticationServices
import Security
import CryptoKit

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
    WebAdBlocker.prepare()
    WebLoginCookies.restore()
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

// Player capability protocols are defined in Protocols.swift.

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

// StreamPlatform is defined in StreamPlatform.swift.

// StreamItem / LayoutMode / PlaybackQuality / AppSettings are defined in Models.swift.

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
  private static let snapshotKey = "web.login.cookies.snapshot.v1"

  static func sync(_ completion: (() -> Void)? = nil) {
    let store = WKWebsiteDataStore.default().httpCookieStore
    store.getAllCookies { cookies in
      let loginCookies = cookies.filter { cookie in
        domains.contains(where: { cookie.domain.contains($0) })
      }
      for cookie in loginCookies {
        HTTPCookieStorage.shared.setCookie(cookie)
      }
      saveSnapshot(loginCookies)
      DispatchQueue.main.async { completion?() }
    }
  }

  static func restore(_ completion: (() -> Void)? = nil) {
    let cookies = loadSnapshot()
    guard !cookies.isEmpty else {
      DispatchQueue.main.async { completion?() }
      return
    }
    let store = WKWebsiteDataStore.default().httpCookieStore
    let group = DispatchGroup()
    for cookie in cookies {
      HTTPCookieStorage.shared.setCookie(cookie)
      group.enter()
      store.setCookie(cookie) {
        group.leave()
      }
    }
    group.notify(queue: .main) {
      completion?()
    }
  }

  static func clearAll(completion: @escaping () -> Void) {
    UserDefaults.standard.removeObject(forKey: snapshotKey)
    if let cookies = HTTPCookieStorage.shared.cookies {
      cookies
        .filter { cookie in domains.contains(where: { cookie.domain.contains($0) }) }
        .forEach { HTTPCookieStorage.shared.deleteCookie($0) }
    }
    let store = WKWebsiteDataStore.default()
    store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
      let targets = records.filter { record in
        let name = record.displayName.lowercased()
        return domains.contains(where: { domain in
          let bare = domain
            .replacingOccurrences(of: ".jp", with: "")
            .replacingOccurrences(of: ".com", with: "")
          return name.contains(domain) || name.contains(bare)
        })
      }
      store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: targets) {
        DispatchQueue.main.async { completion() }
      }
    }
  }

  static func hasCookie(named name: String, domainContains domain: String) -> Bool {
    if HTTPCookieStorage.shared.cookies?.contains(where: {
      $0.name == name && !$0.value.isEmpty && $0.domain.contains(domain)
    }) == true {
      return true
    }
    return loadSnapshot().contains {
      $0.name == name && !$0.value.isEmpty && $0.domain.contains(domain)
    }
  }

  private static func saveSnapshot(_ cookies: [HTTPCookie]) {
    guard !cookies.isEmpty else { return }
    let merged = (loadSnapshot() + cookies).reduce(into: [String: HTTPCookie]()) { result, cookie in
      let key = "\(cookie.domain)|\(cookie.path)|\(cookie.name)"
      result[key] = cookie
    }.values
    let rows = merged.compactMap { cookie -> [String: Any]? in
      var row: [String: Any] = [
        "name": cookie.name,
        "value": cookie.value,
        "domain": cookie.domain,
        "path": cookie.path,
        "secure": cookie.isSecure
      ]
      if let expires = cookie.expiresDate {
        row["expires"] = expires.timeIntervalSince1970
      }
      return row
    }
    UserDefaults.standard.set(rows, forKey: snapshotKey)
  }

  private static func loadSnapshot() -> [HTTPCookie] {
    guard let rows = UserDefaults.standard.array(forKey: snapshotKey) as? [[String: Any]] else { return [] }
    return rows.compactMap { row in
      guard let name = row["name"] as? String,
            let value = row["value"] as? String,
            let domain = row["domain"] as? String,
            let path = row["path"] as? String else { return nil }
      var props: [HTTPCookiePropertyKey: Any] = [
        .name: name,
        .value: value,
        .domain: domain,
        .path: path
      ]
      if let secure = row["secure"] as? Bool, secure {
        props[.secure] = "TRUE"
      }
      if let expires = row["expires"] as? TimeInterval {
        props[.expires] = Date(timeIntervalSince1970: expires)
      }
      return HTTPCookie(properties: props)
    }
  }
}

enum WebAdBlocker {
  private static let identifier = "MultiViewWebAdBlocker"
  private static var ruleList: WKContentRuleList?
  private static var isCompiling = false

  static func prepare() {
    guard Store.loadSettings().blockWebAds else { return }
    compileIfNeeded()
  }

  static func install(on configuration: WKWebViewConfiguration) {
    guard Store.loadSettings().blockWebAds else { return }
    if let ruleList {
      configuration.userContentController.add(ruleList)
      return
    }
    compileIfNeeded()
  }

  private static func compileIfNeeded() {
    guard !isCompiling, ruleList == nil else { return }
    isCompiling = true
    WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: identifier,
      encodedContentRuleList: rulesJSON
    ) { list, _ in
      isCompiling = false
      ruleList = list
    }
  }

  private static let rulesJSON = """
  [
    {"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","raw","media"],"if-domain":["doubleclick.net","googlesyndication.com","googleadservices.com","adservice.google.com","pagead2.googlesyndication.com","ads.youtube.com","imasdk.googleapis.com","pubads.g.doubleclick.net","securepubads.g.doubleclick.net","amazon-adsystem.com","adnxs.com","adsystem.com","taboola.com","outbrain.com"]},"action":{"type":"block"}}
  ]
  """
}

final class NiconicoWarmup: NSObject, WKNavigationDelegate {
  static let shared = NiconicoWarmup()

  private var webViews: [String: WKWebView] = [:]
  private var completions: [String: [() -> Void]] = [:]
  private var lastFinished: [String: Date] = [:]
  private var reloadCounts: [String: Int] = [:]

  func prewarm(programId rawProgramId: String, forceReload: Bool = false, completion: (() -> Void)? = nil) {
    let programId = rawProgramId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !programId.isEmpty,
          let url = URL(string: "https://live.nicovideo.jp/watch/\(programId)") else {
      completion?()
      return
    }
    if !forceReload, let last = lastFinished[programId], Date().timeIntervalSince(last) < 30 {
      WebLoginCookies.restore {
        WebLoginCookies.sync(completion)
      }
      return
    }
    if let completion {
      completions[programId, default: []].append(completion)
    }
    if let existing = webViews[programId] {
      reloadCounts[programId] = 0
      WebLoginCookies.restore {
        existing.load(URLRequest(url: url))
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
        self?.complete(programId: programId)
      }
      return
    }

    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    config.websiteDataStore = .default()
    WebAdBlocker.install(on: config)
    let web = WKWebView(frame: CGRect(x: -240, y: -240, width: 160, height: 160), configuration: config)
    web.customUserAgent = NiconicoNativePlayerView.userAgent
    web.navigationDelegate = self
    web.alpha = 0.01
    web.isUserInteractionEnabled = false
    web.accessibilityIdentifier = programId
    webViews[programId] = web
    reloadCounts[programId] = 0

    if let window = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow }) {
      web.frame = CGRect(x: 0, y: window.bounds.maxY - 1, width: 1, height: 1)
      window.addSubview(web)
    }
    WebLoginCookies.restore {
      web.load(URLRequest(url: url))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
      self?.complete(programId: programId)
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let programId = webView.accessibilityIdentifier else { return }
    let count = reloadCounts[programId] ?? 0
    guard count > 0 else {
      reloadCounts[programId] = count + 1
      WebLoginCookies.sync {
        WebLoginCookies.restore {
          webView.reload()
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
        self?.complete(programId: programId)
      }
      return
    }
    complete(programId: programId)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    complete(programId: webView.accessibilityIdentifier)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    complete(programId: webView.accessibilityIdentifier)
  }

  private func complete(programId: String?) {
    guard let programId, webViews[programId] != nil else { return }
    lastFinished[programId] = Date()
    let callbacks = completions.removeValue(forKey: programId) ?? []
    WebLoginCookies.sync {
      callbacks.forEach { $0() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
      guard let self,
            let last = self.lastFinished[programId],
            Date().timeIntervalSince(last) >= 90 else { return }
      self.webViews[programId]?.navigationDelegate = nil
      self.webViews[programId]?.stopLoading()
      self.webViews[programId]?.removeFromSuperview()
      self.webViews.removeValue(forKey: programId)
      self.lastFinished.removeValue(forKey: programId)
      self.reloadCounts.removeValue(forKey: programId)
    }
  }
}

// OAuth managers / configs / keychain / live-chat DTOs are defined in OAuth.swift.

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
    if platform == .niconico {
      NiconicoWarmup.shared.prewarm(programId: channel)
    }
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
    WebAdBlocker.install(on: config)
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
      URLQueryItem(name: "vol", value: String(StreamVolumeStore.volume(for: stream)))
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

// Danmaku & Niconico gift rendering helpers are defined in Rendering.swift.

// The five native player views (Niconico/Kick/Twitch/TwitCasting/YouTube) are defined in Players.swift.

final class ViewingController: UIViewController {
  private let scrollView = UIScrollView()
  private let stack = UIStackView()
  private var focused: StreamItem?
  private weak var dragSourceCell: StreamCellView?
  private weak var dragTargetCell: StreamCellView?
  private let reorderIndicator = UIView()
  private var dragSnapshot: UIView?
  private var dragSourceStream: StreamItem?
  private var dragInsertIndex: Int?
  private var lastAutoReloadAt = Date.distantPast

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)
    configureScroll()
    configureReorderIndicator()
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
    resumePlaybackAfterReload()
  }

  private func resumePlaybackAfterReload() {
    [0.2, 0.6, 1.2, 2.4].forEach { delay in
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        PlaybackCoordinator.shared.resumeAll()
      }
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
      let focusedView = FocusedStreamView(stream: focused, onClose: { [weak self] in
        self?.focused = nil
        self?.reload()
      })
      stack.addArrangedSubview(focusedView)
      // 展開（1配信フル表示）は可視領域いっぱいに広げる（再生バー＋余白分を引いた高さ）。
      focusedView.heightAnchor.constraint(
        equalTo: scrollView.frameLayoutGuide.heightAnchor, constant: -80
      ).isActive = true
      PlaybackCoordinator.shared.resumeAll()
      return
    }
    // Every platform now has a dedicated per-cell native player, so all streams go
    // through addCells (grid / stacked). The old single-WebView fallback is gone.
    addCells(streams)
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

    let addButton = iconButton(systemName: "plus", accessibilityLabel: "追加") { [weak self] in
      self?.present(AddStreamController(), animated: true)
    }
    let reloadButton = iconButton(systemName: "arrow.triangle.2.circlepath", accessibilityLabel: "更新") { [weak self] in
      self?.reload()
      self?.resumePlaybackAfterReload()
    }
    row.addArrangedSubview(layoutControl)
    row.addArrangedSubview(spacer)
    row.addArrangedSubview(addButton)
    row.addArrangedSubview(reloadButton)

    stack.addArrangedSubview(host)
    NSLayoutConstraint.activate([
      host.heightAnchor.constraint(equalToConstant: 40),
      row.centerYAnchor.constraint(equalTo: host.centerYAnchor),
      row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      layoutControl.widthAnchor.constraint(equalToConstant: 96),
      layoutControl.heightAnchor.constraint(equalToConstant: 34),
      addButton.widthAnchor.constraint(equalToConstant: 38),
      addButton.heightAnchor.constraint(equalToConstant: 36),
      reloadButton.widthAnchor.constraint(equalToConstant: 46),
      reloadButton.heightAnchor.constraint(equalToConstant: 36)
    ])
  }

  private func iconButton(systemName: String, accessibilityLabel: String, action: @escaping () -> Void) -> UIButton {
    let button = LiquidGlass.makeButton(title: nil, systemImage: systemName, tint: nil)
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    button.accessibilityLabel = accessibilityLabel
    return button
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
    // Pairs go two-up; the trailing stream(s) get their own full-width row so they
    // read as the "main" view and no empty space is left beside a cell.
    //   - odd count : the last 1 stream is full-width (大きい表示 末尾1つ)
    //   - even count: the last 2 streams are full-width, stacked (大きい表示 2つ)
    let bigCount = streams.count % 2 == 0 ? 2 : 1
    let pairedCount = streams.count - bigCount
    var index = 0
    while index + 1 < pairedCount {
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
    while index < streams.count {
      addStackedCell(streams[index])
      index += 1
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

  private func configureReorderIndicator() {
    reorderIndicator.backgroundColor = .systemGreen
    reorderIndicator.layer.cornerRadius = 2
    reorderIndicator.layer.shadowColor = UIColor.black.cgColor
    reorderIndicator.layer.shadowOpacity = 0.24
    reorderIndicator.layer.shadowRadius = 8
    reorderIndicator.layer.shadowOffset = CGSize(width: 0, height: 3)
    reorderIndicator.isHidden = true
    reorderIndicator.alpha = 0
    view.addSubview(reorderIndicator)
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
    view.bringSubviewToFront(reorderIndicator)
    view.bringSubviewToFront(snapshot)
    dragSnapshot = snapshot
    updateReorder(at: location)
  }

  private func updateReorder(at location: CGPoint) {
    dragSnapshot?.center = location
    guard let target = reorderCell(at: location),
          let targetIndex = AppState.shared.streams.firstIndex(where: { $0.id == target.stream.id }) else {
      dragInsertIndex = nil
      hideReorderIndicator()
      return
    }
    if target !== dragTargetCell {
      dragTargetCell?.setDropTargetActive(false)
      dragTargetCell = target
      if target !== dragSourceCell {
        target.setDropTargetActive(true)
      }
    }
    let frame = target.convert(target.bounds, to: view)
    let insertAfterTarget = location.y > frame.midY
    dragInsertIndex = targetIndex + (insertAfterTarget ? 1 : 0)
    showReorderIndicator(near: frame, after: insertAfterTarget)
  }

  private func finishReorder(commit: Bool) {
    scrollView.isScrollEnabled = true
    let sourceCell = dragSourceCell
    let targetCell = dragTargetCell
    let sourceStream = dragSourceStream
    let insertIndex = dragInsertIndex
    dragSourceCell = nil
    dragTargetCell = nil
    dragSourceStream = nil
    dragInsertIndex = nil

    sourceCell?.setReorderSourceActive(false)
    targetCell?.setDropTargetActive(false)
    hideReorderIndicator()

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
          let from = AppState.shared.streams.firstIndex(where: { $0.id == sourceStream.id }),
          let insertIndex,
          insertIndex != from,
          insertIndex != from + 1 else { return }
    var next = AppState.shared.streams
    let moved = next.remove(at: from)
    let adjustedInsertIndex = from < insertIndex ? insertIndex - 1 : insertIndex
    next.insert(moved, at: max(0, min(adjustedInsertIndex, next.count)))
    AppState.shared.streams = next
  }

  private func showReorderIndicator(near targetFrame: CGRect, after: Bool) {
    let y = after ? targetFrame.maxY : targetFrame.minY
    let frame = CGRect(x: targetFrame.minX + 10, y: y - 2, width: max(24, targetFrame.width - 20), height: 4)
    if reorderIndicator.isHidden {
      reorderIndicator.frame = frame
      reorderIndicator.transform = CGAffineTransform(scaleX: 0.86, y: 1)
      reorderIndicator.isHidden = false
      UIView.animate(withDuration: 0.18, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.3, options: [.allowUserInteraction, .beginFromCurrentState]) {
        self.reorderIndicator.alpha = 1
        self.reorderIndicator.transform = .identity
      }
      return
    }
    UIView.animate(withDuration: 0.16, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
      self.reorderIndicator.frame = frame
    }
  }

  private func hideReorderIndicator() {
    guard !reorderIndicator.isHidden else { return }
    UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
      self.reorderIndicator.alpha = 0
    } completion: { _ in
      self.reorderIndicator.isHidden = true
      self.reorderIndicator.transform = .identity
    }
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
  private weak var commentEchoer: CommentEchoDisplay?

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
    commentEchoer = video as? CommentEchoDisplay
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
        self?.commentEchoer?.emitOwnComment(text)
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
  private weak var commentPoster: CommentPostable?
  private weak var commentEchoer: CommentEchoDisplay?

  init(stream: StreamItem, onClose: (() -> Void)?) {
    self.stream = stream
    let chatURL = FocusedStreamView.chatURL(for: stream)
    if let chatURL {
      let config = WKWebViewConfiguration()
      config.allowsInlineMediaPlayback = true
      config.websiteDataStore = .default()
      WebAdBlocker.install(on: config)
      chatWeb = WKWebView(frame: .zero, configuration: config)
      // YouTube の live_chat 埋め込みはモバイルWeb非対応で、WKWebView標準UA(モバイル)では
      // 「チャットをご利用いただけません。ブラウザのバージョンが古いようです」と出て表示されない。
      // デスクトップ Safari の UA を名乗るとデスクトップ版 live_chat が返り、正しく表示される。
      if stream.platform == .youtube {
        chatWeb?.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
      }
      chatWeb?.load(URLRequest(url: chatURL))
    } else {
      chatWeb = nil
    }
    super.init(frame: .zero)
    backgroundColor = .black
    // 高さは ViewingController 側で可視領域いっぱいに設定する。ここでは最低限のフロアだけ
    // （必須より低い優先度なので、全画面表示の equalTo 制約と衝突しない）。
    let minHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: 320)
    minHeight.priority = UILayoutPriority(749)
    minHeight.isActive = true

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
    commentEchoer = video as? CommentEchoDisplay
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

    // 拡大表示は「ブラウザ(チャット)を大きく上に・プレイヤーを小さく下に」配置する。
    // 以前は逆 (プレイヤー全面＋下にチャット小窓) で、チャットが小さく見にくかった。
    var constraints: [NSLayoutConstraint] = [
      chatPanel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      chatPanel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      chatPanel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      chatPanel.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -8),
      input.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      input.bottomAnchor.constraint(equalTo: video.topAnchor, constant: -8),
      input.heightAnchor.constraint(equalToConstant: 40),
      send.leadingAnchor.constraint(equalTo: input.trailingAnchor, constant: 8),
      send.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      send.centerYAnchor.constraint(equalTo: input.centerYAnchor),
      send.widthAnchor.constraint(equalToConstant: 54),
      video.leadingAnchor.constraint(equalTo: leadingAnchor),
      video.trailingAnchor.constraint(equalTo: trailingAnchor),
      video.bottomAnchor.constraint(equalTo: bottomAnchor),
      video.heightAnchor.constraint(equalTo: widthAnchor, multiplier: 9.0 / 16.0),
      remove.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      remove.widthAnchor.constraint(equalToConstant: 36),
      remove.heightAnchor.constraint(equalToConstant: 36),
      volume.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      volume.centerYAnchor.constraint(equalTo: video.centerYAnchor),
      volume.widthAnchor.constraint(equalToConstant: 42),
      volume.heightAnchor.constraint(equalTo: video.heightAnchor, multiplier: 0.7)
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
    // close/remove/volume は chatPanel より先に addSubview したため、上に来たチャットパネルに
    // 隠れて見えなくなる（×ボタンが出ない不具合）。操作ボタン群を最前面に出す。
    bringSubviewToFront(volume)
    bringSubviewToFront(remove)
    if let closeButton { bringSubviewToFront(closeButton) }
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
    if let commentPoster {
      commentPoster.postComment(text) { [weak self] result in
        DispatchQueue.main.async {
          switch result {
          case .success:
            self?.input.text = ""
            self?.commentEchoer?.emitOwnComment(text)
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
    WebAdBlocker.install(on: config)
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    return WKWebView(frame: .zero, configuration: config)
  }()
  private var activeSources = [(StreamPlatform, Source)]()
  fileprivate static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)
    // Kick (and others) sit behind Cloudflare bot protection that 400s requests that
    // don't look like a real browser. A blank WKWebView sends a stripped UA, so
    // kick.com/following 400s; advertising a real mobile Safari UA lets Cloudflare
    // serve its JS challenge (which WKWebView, being WebKit, can actually solve).
    web.customUserAgent = Self.browserUserAgent
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
    let request = URLRequest(url: activeSources[segmented.selectedSegmentIndex].1.url)
    WebLoginCookies.restore { [weak self] in
      self?.web.load(request)
    }
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

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    WebLoginCookies.sync()
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
    if host.contains("youtube.com"),
       let first = parts.first,
       ["live", "embed", "shorts"].contains(first),
       parts.count > 1 {
      return (.youtube, parts[1])
    }
    if host.contains("youtube.com"),
       let first = parts.first,
       first.hasPrefix("@") || ["channel", "c", "user"].contains(first) {
      return (.youtube, parts.joined(separator: "/"))
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

// Niconico has no public OAuth for third-party live posting, so login is web-based.
// The user_session cookie persists in WKWebsiteDataStore + HTTPCookieStorage and is
// reused by the native player/comment/post code.
enum NiconicoSession {
  private static let snapshotKey = "web.login.cookies.snapshot.v1"

  static var isLoggedIn: Bool {
    guard let url = URL(string: "https://live.nicovideo.jp/"),
          let cookies = HTTPCookieStorage.shared.cookies(for: url) else {
      return WebLoginCookies.hasCookie(named: "user_session", domainContains: "nicovideo.jp")
    }
    return cookies.contains { $0.name == "user_session" && !$0.value.isEmpty }
      || WebLoginCookies.hasCookie(named: "user_session", domainContains: "nicovideo.jp")
  }

  static func logout(completion: @escaping () -> Void) {
    if let url = URL(string: "https://live.nicovideo.jp/"),
       let cookies = HTTPCookieStorage.shared.cookies(for: url) {
      cookies.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
    }
    let store = WKWebsiteDataStore.default()
    store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
      let nico = records.filter { $0.displayName.contains("nicovideo") || $0.displayName.contains("nimg") }
      store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: nico) {
        removeSnapshotCookies(matching: { $0.domain.contains("nicovideo.jp") || $0.domain.contains("nimg.jp") })
        DispatchQueue.main.async { completion() }
      }
    }
  }

  private static func removeSnapshotCookies(matching shouldRemove: (HTTPCookie) -> Bool) {
    guard let rows = UserDefaults.standard.array(forKey: snapshotKey) as? [[String: Any]] else { return }
    let kept = rows.filter { row in
      guard let name = row["name"] as? String,
            let value = row["value"] as? String,
            let domain = row["domain"] as? String,
            let path = row["path"] as? String else { return true }
      var props: [HTTPCookiePropertyKey: Any] = [
        .name: name,
        .value: value,
        .domain: domain,
        .path: path
      ]
      if let cookie = HTTPCookie(properties: props) {
        return !shouldRemove(cookie)
      }
      return true
    }
    UserDefaults.standard.set(kept, forKey: snapshotKey)
  }
}

final class NiconicoLoginController: UIViewController, WKNavigationDelegate {
  private let web: WKWebView = {
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    config.websiteDataStore = .default()
    WebAdBlocker.install(on: config)
    return WKWebView(frame: .zero, configuration: config)
  }()

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "ニコ生ログイン"
    view.backgroundColor = .black
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完了", style: .done, target: self, action: #selector(done))
    web.navigationDelegate = self
    web.customUserAgent = NiconicoNativePlayerView.userAgent
    web.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(web)
    NSLayoutConstraint.activate([
      web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      web.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
    if let url = URL(string: "https://account.nicovideo.jp/login?site=niconico&next_url=%2F") {
      web.load(URLRequest(url: url))
    }
  }

  @objc private func done() {
    // Pull the fresh login cookie into the native jar the players use, then close.
    WebLoginCookies.sync { [weak self] in self?.dismiss(animated: true) }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    WebLoginCookies.sync()
  }
}

final class SettingsController: UITableViewController {
  private var platforms: [StreamPlatform] { AppState.shared.settings.platformOrder }

  override func viewDidLoad() {
    super.viewDidLoad()
    tableView.backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)
    tableView.separatorColor = UIColor.white.withAlphaComponent(0.12)
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    tableView.isEditing = true
    tableView.allowsSelectionDuringEditing = true
    tableView.estimatedSectionFooterHeight = 72
    tableView.sectionFooterHeight = UITableView.automaticDimension
  }

  func reload() {
    guard isViewLoaded else { return }
    tableView.reloadData()
  }

  // Settings are grouped so related items live together and each service's account
  // setup is its own clearly-labelled section (the old layout mixed playback with
  // danmaku and scattered OAuth across confusing rows).
  private enum Sec: Int, CaseIterable {
    case playback, danmaku, order, kick, twitch, twitcasting, youtube, niconico, webData, add
  }

  private func switchControl(isOn: Bool, onChange: @escaping (Bool) -> Void) -> UISwitch {
    let toggle = UISwitch()
    toggle.isOn = isOn
    toggle.addAction(UIAction { action in
      guard let s = action.sender as? UISwitch else { return }
      onChange(s.isOn)
    }, for: .valueChanged)
    return toggle
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // Refresh login states (e.g. after returning from the niconico web login).
    reload()
  }

  override func numberOfSections(in tableView: UITableView) -> Int { Sec.allCases.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    guard let sec = Sec(rawValue: section) else { return 0 }
    switch sec {
    case .playback: return 5
    case .danmaku: return 6
    case .order: return platforms.count
    case .kick: return 5
    case .twitch: return 4
    case .twitcasting: return 4
    case .youtube: return 5
    case .niconico: return 2
    case .webData: return 1
    case .add: return 1
    }
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    guard let sec = Sec(rawValue: section) else { return nil }
    switch sec {
    case .playback: return "再生・画質"
    case .danmaku: return "弾幕"
    case .order: return "サービス順"
    case .kick: return "Kick 連携"
    case .twitch: return "Twitch 連携"
    case .twitcasting: return "ツイキャス 連携"
    case .youtube: return "YouTube 連携"
    case .niconico: return "ニコ生 連携"
    case .webData: return "ログイン情報"
    case .add: return "追加"
    }
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    nil
  }

  private func footerText(for section: Int) -> String? {
    guard let sec = Sec(rawValue: section) else { return nil }
    switch sec {
    case .order:
      return "右端の並べ替えハンドルをドラッグして、表示順を自由に変更できます。"
    case .kick:
      return "Kick Developer でOAuthアプリを作成します。Redirect URI「\(KickAuthManager.shared.config.redirectURI)」を登録してください。"
    case .twitch:
      return "Twitch Developer Console でアプリを作成します。Redirect URI はHTTPS必須なので「\(TwitchAuthManager.shared.config.redirectURI)」を登録してください。"
    case .twitcasting:
      return "ツイキャスのAPIアプリ(Write権限)の Client ID を設定し、Redirect URI を登録してください(行をタップでコピー)。"
    case .youtube:
      return "YouTubeコメント弾幕・投稿には Google Cloud の iOS OAuth Client ID と YouTube Data API v3 が必要です。手順は「設定手順を表示」を開いて確認できます。"
    case .niconico:
      return "ニコ生はログイン必須です。公式の外部連携(OAuth)が無いため、Webでログインします。ログイン状態はアプリ内のCookieに保持され、視聴・コメント投稿・コメント受信に使われます。"
    case .webData:
      return "フォロー・ランキング・視聴タブで使うWebログインCookieと閲覧データを削除します。OAuthトークンとClient ID設定は残ります。"
    case .add:
      let info = Bundle.main.infoDictionary
      let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
      let build = (info?["CFBundleVersion"] as? String) ?? "?"
      return "MultiView \(version) (build \(build))"
    default:
      return nil
    }
  }

  override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
    guard let text = footerText(for: section) else { return nil }
    let container = UIView()
    let label = UILabel()
    label.text = text
    label.textColor = UIColor.white.withAlphaComponent(0.56)
    label.font = .systemFont(ofSize: 12)
    label.numberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(label)
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
      label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
      label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
    ])
    return container
  }

  override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
    footerText(for: section) == nil ? CGFloat.leastNormalMagnitude : UITableView.automaticDimension
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
    cell.backgroundColor = UIColor.white.withAlphaComponent(0.06)
    cell.textLabel?.textColor = .white
    cell.selectionStyle = .none
    cell.accessoryView = nil
    cell.accessoryType = .none
    cell.editingAccessoryView = nil
    cell.editingAccessoryType = .none
    cell.showsReorderControl = false
    cell.textLabel?.numberOfLines = 0
    cell.textLabel?.lineBreakMode = .byWordWrapping

    guard let sec = Sec(rawValue: indexPath.section) else { return cell }
    switch sec {
    case .playback:
      switch indexPath.row {
      case 0:
        cell.textLabel?.text = "音声を有効にして開始"
        cell.accessoryView = switchControl(isOn: AppState.shared.settings.playAudio) { v in
          var s = AppState.shared.settings; s.playAudio = v; AppState.shared.settings = s
        }
      case 1:
        cell.textLabel?.text = "レイド先を自動追加"
        cell.accessoryView = switchControl(isOn: AppState.shared.settings.autoFollowRaids) { v in
          var s = AppState.shared.settings; s.autoFollowRaids = v; AppState.shared.settings = s
        }
      case 2:
        cell.textLabel?.text = "Web広告ブロック"
        cell.accessoryView = switchControl(isOn: AppState.shared.settings.blockWebAds) { v in
          var s = AppState.shared.settings
          s.blockWebAds = v
          AppState.shared.settings = s
          if v { WebAdBlocker.prepare() }
        }
      case 3:
        cell.textLabel?.text = "Wi-Fi時の画質"
        cell.accessoryView = qualityControl(selected: AppState.shared.settings.wifiQuality) { quality in
          var s = AppState.shared.settings; s.wifiQuality = quality; AppState.shared.settings = s
        }
      default:
        cell.textLabel?.text = "モバイル通信時の画質"
        cell.accessoryView = qualityControl(selected: AppState.shared.settings.mobileQuality) { quality in
          var s = AppState.shared.settings; s.mobileQuality = quality; AppState.shared.settings = s
        }
      }
    case .danmaku:
      if indexPath.row == 0 {
        cell.textLabel?.text = "弾幕を表示"
        cell.accessoryView = switchControl(isOn: AppState.shared.settings.showChat) { v in
          var s = AppState.shared.settings; s.showChat = v; AppState.shared.settings = s
        }
      } else {
        cell.textLabel?.text = danmakuTitle(field: indexPath.row - 1)
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
      }
    case .order:
      cell.textLabel?.text = platforms[indexPath.row].label
      cell.showsReorderControl = true
    case .kick:
      let config = KickAuthManager.shared.config
      switch indexPath.row {
      case 0: cell.textLabel?.text = KickAuthManager.shared.isSignedIn ? "ログアウト" : "ログイン"
      case 1: cell.textLabel?.text = "Kick Developer を開く"
      case 2: cell.textLabel?.text = config.clientId.isEmpty ? "Client ID 未設定" : "Client ID 設定済み"
      case 3: cell.textLabel?.text = config.clientSecret.isEmpty ? "Client Secret 未設定 (任意)" : "Client Secret 設定済み"
      default: cell.textLabel?.text = "Redirect URI をコピー"
      }
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    case .twitch:
      switch indexPath.row {
      case 0: cell.textLabel?.text = TwitchAuthManager.shared.isSignedIn ? "ログアウト" : "ログイン"
      case 1: cell.textLabel?.text = "Twitch Developer Console を開く"
      case 2: cell.textLabel?.text = TwitchAuthManager.shared.config.clientId.isEmpty ? "Client ID 未設定" : "Client ID 設定済み"
      default: cell.textLabel?.text = "Redirect URI をコピー"
      }
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    case .twitcasting:
      switch indexPath.row {
      case 0: cell.textLabel?.text = TwitcastingAuthManager.shared.isSignedIn ? "ログアウト" : "ログイン"
      case 1: cell.textLabel?.text = "ツイキャス API 管理を開く"
      case 2: cell.textLabel?.text = TwitcastingAuthManager.shared.config.clientId.isEmpty ? "Client ID 未設定" : "Client ID 設定済み"
      default: cell.textLabel?.text = "Redirect URI をコピー"
      }
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    case .youtube:
      switch indexPath.row {
      case 0: cell.textLabel?.text = YouTubeAuthManager.shared.isSignedIn ? "ログアウト" : "ログイン"
      case 1: cell.textLabel?.text = "Google Cloud 認証情報を開く"
      case 2: cell.textLabel?.text = YouTubeAuthManager.shared.config.clientId.isEmpty ? "Client ID 未設定" : "Client ID 設定済み"
      case 3: cell.textLabel?.text = "設定手順を表示"
      default: cell.textLabel?.text = "Redirect URI をコピー"
      }
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    case .niconico:
      if indexPath.row == 0 {
        cell.textLabel?.text = NiconicoSession.isLoggedIn ? "ログイン済み（再ログイン）" : "ニコ生にログイン"
      } else {
        cell.textLabel?.text = "ログアウト"
        cell.textLabel?.textColor = NiconicoSession.isLoggedIn ? .systemRed : UIColor.white.withAlphaComponent(0.4)
      }
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    case .webData:
      cell.textLabel?.text = "Webログイン情報と履歴を削除"
      cell.textLabel?.textColor = .systemRed
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    case .add:
      cell.textLabel?.text = "配信を手動追加"
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    }
    // The table stays in editing mode for drag-reordering, and editing mode shows
    // editingAccessory* instead of accessory* — without this the switches and quality
    // controls vanish. Mirror whatever we configured above onto the editing slots.
    cell.editingAccessoryType = cell.accessoryType
    if let control = cell.accessoryView {
      cell.editingAccessoryView = control
      cell.accessoryView = nil
    }
    return cell
  }

  override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
    indexPath.section == Sec.order.rawValue
  }

  override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
    .none
  }

  override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
    false
  }

  override func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
    proposedDestinationIndexPath.section == Sec.order.rawValue ? proposedDestinationIndexPath : sourceIndexPath
  }

  override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
    guard sourceIndexPath.section == Sec.order.rawValue, destinationIndexPath.section == Sec.order.rawValue else { return }
    var settings = AppState.shared.settings
    let moved = settings.platformOrder.remove(at: sourceIndexPath.row)
    settings.platformOrder.insert(moved, at: destinationIndexPath.row)
    AppState.shared.settings = settings
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard let sec = Sec(rawValue: indexPath.section) else { return }
    switch sec {
    case .danmaku:
      if indexPath.row >= 1 { editDanmakuValue(field: indexPath.row - 1) }
    case .kick:
      handleKickOAuthRow(indexPath.row)
    case .twitch:
      handleOtherOAuthRow(indexPath.row)
    case .twitcasting:
      handleOtherOAuthRow(indexPath.row + 4)
    case .youtube:
      handleYouTubeOAuthRow(indexPath.row)
    case .niconico:
      handleNiconicoRow(indexPath.row)
    case .webData:
      confirmClearWebData()
    case .add:
      present(AddStreamController(), animated: true)
    default:
      break
    }
  }

  private func danmakuTitle(field: Int) -> String {
    let settings = AppState.shared.settings
    switch field {
    case 0:
      return "文字サイズ \(Int(settings.danmakuFontSize))"
    case 1:
      return "速度 \(Int((settings.danmakuSpeed / 0.13) * 100))%"
    case 2:
      return "透過度 \(Int(settings.danmakuOpacity * 100))%"
    case 3:
      return "最大行数 \(settings.danmakuMaxLines == 0 ? "自動" : String(settings.danmakuMaxLines))"
    default:
      return "最大文字数 \(settings.danmakuMaxLength == 0 ? "無制限" : String(settings.danmakuMaxLength))"
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

  private func editDanmakuValue(field: Int) {
    let settings = AppState.shared.settings
    let current: String
    let title: String
    let message: String
    switch field {
    case 0:
      title = "文字サイズ"
      current = String(Int(settings.danmakuFontSize))
      message = "12〜40"
    case 1:
      title = "速度"
      current = String(Int((settings.danmakuSpeed / 0.13) * 100))
      message = "100が標準"
    case 2:
      title = "透過度"
      current = String(Int(settings.danmakuOpacity * 100))
      message = "30〜100"
    case 3:
      title = "最大行数"
      current = String(settings.danmakuMaxLines)
      message = "0で自動"
    default:
      title = "最大文字数"
      current = String(settings.danmakuMaxLength)
      message = "0で無制限"
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
      switch field {
      case 0:
        settings.danmakuFontSize = min(40, max(12, value.rounded()))
      case 1:
        settings.danmakuSpeed = min(300, max(20, value)) / 100 * 0.13
      case 2:
        settings.danmakuOpacity = min(100, max(30, value)) / 100
      case 3:
        settings.danmakuMaxLines = min(20, max(0, Int(value.rounded())))
      default:
        settings.danmakuMaxLength = min(500, max(0, Int(value.rounded())))
      }
      AppState.shared.settings = settings
      self?.tableView.reloadRows(at: [IndexPath(row: field + 1, section: Sec.danmaku.rawValue)], with: .automatic)
    })
    present(alert, animated: true)
  }

  private func handleKickOAuthRow(_ row: Int) {
    switch row {
    case 0:
      if KickAuthManager.shared.isSignedIn {
        KickAuthManager.shared.signOut()
        tableView.reloadData()
        return
      }
      KickAuthManager.shared.signIn(presentationAnchor: view.window) { [weak self] result in
        DispatchQueue.main.async {
          self?.tableView.reloadData()
          if case .failure(let error) = result {
            self?.presentError(error)
          }
        }
      }
    case 1:
      openDeveloperURL("https://kick.com/settings/developer")
    case 2:
      editKickClientID()
    case 3:
      editKickClientSecret()
    case 4:
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
      self?.tableView.reloadData()
    })
    present(alert, animated: true)
  }

  private func editKickClientSecret() {
    var config = KickAuthManager.shared.config
    let alert = UIAlertController(title: "Kick Client Secret", message: "確認画面付き(confidential)アプリの場合のみ入力してください。PKCEの公開アプリでは空のままで構いません。", preferredStyle: .alert)
    alert.addTextField { field in
      field.text = config.clientSecret
      field.isSecureTextEntry = true
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
    }
    alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
    alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
      config.clientSecret = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      KickAuthManager.shared.config = config
      self?.tableView.reloadData()
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
      self?.tableView.reloadData()
    })
    present(alert, animated: true)
  }

  private func handleOtherOAuthRow(_ row: Int) {
    switch row {
    case 0:
      if TwitchAuthManager.shared.isSignedIn {
        TwitchAuthManager.shared.signOut()
        tableView.reloadData()
        return
      }
      TwitchAuthManager.shared.signIn(presentationAnchor: view.window) { [weak self] result in
        DispatchQueue.main.async {
          self?.tableView.reloadData()
          if case .failure(let error) = result { self?.presentError(error) }
        }
      }
    case 1:
      openDeveloperURL("https://dev.twitch.tv/console/apps")
    case 2:
      editTwitchClientID()
    case 3:
      let uri = TwitchAuthManager.shared.config.redirectURI
      UIPasteboard.general.string = uri
      presentCopiedRedirectAlert(service: "Twitch", uri: uri) { [weak self] in self?.editTwitchRedirectURI() }
    case 4:
      if TwitcastingAuthManager.shared.isSignedIn {
        TwitcastingAuthManager.shared.signOut()
        tableView.reloadData()
        return
      }
      TwitcastingAuthManager.shared.signIn(presentationAnchor: view.window) { [weak self] result in
        DispatchQueue.main.async {
          self?.tableView.reloadData()
          if case .failure(let error) = result { self?.presentError(error) }
        }
      }
    case 5:
      openDeveloperURL("https://twitcasting.tv/developer.php")
    case 6:
      editTwitcastingClientID()
    case 7:
      let uri = TwitcastingAuthManager.shared.config.redirectURI
      UIPasteboard.general.string = uri
      presentCopiedRedirectAlert(service: "ツイキャス", uri: uri) { [weak self] in self?.editTwitcastingRedirectURI() }
    default:
      break
    }
  }

  private func handleYouTubeOAuthRow(_ row: Int) {
    switch row {
    case 0:
      if YouTubeAuthManager.shared.isSignedIn {
        YouTubeAuthManager.shared.signOut()
        tableView.reloadData()
        return
      }
      YouTubeAuthManager.shared.signIn(presentationAnchor: view.window) { [weak self] result in
        DispatchQueue.main.async {
          self?.tableView.reloadData()
          if case .failure(let error) = result { self?.presentError(error) }
        }
      }
    case 1:
      openDeveloperURL("https://console.cloud.google.com/apis/credentials")
    case 2:
      editYouTubeClientID()
    case 3:
      presentYouTubeSetupGuide()
    case 4:
      let uri = YouTubeAuthManager.effectiveRedirectURI(for: YouTubeAuthManager.shared.config)
      UIPasteboard.general.string = uri
      presentCopiedRedirectAlert(service: "YouTube", uri: uri) { [weak self] in self?.editYouTubeRedirectURI() }
    default:
      break
    }
  }

  private func openDeveloperURL(_ raw: String) {
    guard let url = URL(string: raw) else { return }
    UIApplication.shared.open(url)
  }

  private func editTwitchClientID() {
    var config = TwitchAuthManager.shared.config
    editText(title: "Twitch Client ID", message: "Twitch Developer Consoleで作成したアプリの Client ID を貼り付けてください。", text: config.clientId, keyboard: .default) { [weak self] value in
      config.clientId = value
      TwitchAuthManager.shared.config = config
      self?.tableView.reloadData()
    }
  }

  private func editTwitchRedirectURI() {
    var config = TwitchAuthManager.shared.config
    editText(title: "Twitch Redirect URI", message: nil, text: config.redirectURI, keyboard: .URL) { [weak self] value in
      config.redirectURI = value
      TwitchAuthManager.shared.config = config
      self?.tableView.reloadData()
    }
  }

  private func editTwitcastingClientID() {
    var config = TwitcastingAuthManager.shared.config
    editText(title: "ツイキャス Client ID", message: "ツイキャスのAPIアプリ設定で発行された Client ID を貼り付けてください。", text: config.clientId, keyboard: .default) { [weak self] value in
      config.clientId = value
      TwitcastingAuthManager.shared.config = config
      self?.tableView.reloadData()
    }
  }

  private func editTwitcastingRedirectURI() {
    var config = TwitcastingAuthManager.shared.config
    editText(title: "ツイキャス Redirect URI", message: nil, text: config.redirectURI, keyboard: .URL) { [weak self] value in
      config.redirectURI = value
      TwitcastingAuthManager.shared.config = config
      self?.tableView.reloadData()
    }
  }

  private func editYouTubeClientID() {
    var config = YouTubeAuthManager.shared.config
    editText(title: "YouTube Client ID", message: "Google Cloud Consoleで作成したiOS OAuth Client IDを貼り付けてください。", text: config.clientId, keyboard: .default) { [weak self] value in
      config.clientId = value
      if config.redirectURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || config.redirectURI.hasPrefix("multiview://"),
         let redirectURI = YouTubeAuthManager.defaultRedirectURI(forClientID: value) {
        config.redirectURI = redirectURI
      }
      YouTubeAuthManager.shared.config = config
      self?.tableView.reloadData()
    }
  }

  private func editYouTubeRedirectURI() {
    var config = YouTubeAuthManager.shared.config
    editText(title: "YouTube Redirect URI", message: nil, text: config.redirectURI, keyboard: .URL) { [weak self] value in
      config.redirectURI = value
      YouTubeAuthManager.shared.config = config
      self?.tableView.reloadData()
    }
  }

  private func presentYouTubeSetupGuide() {
    let config = YouTubeAuthManager.shared.config
    let redirectURI = YouTubeAuthManager.effectiveRedirectURI(for: config)
    let message = """
    1. Google Cloud Consoleでプロジェクトを開きます。
    2. 「APIとサービス」>「ライブラリ」で YouTube Data API v3 を有効化します。
    3. 「OAuth同意画面」でアプリを作成します。公開状態がテストの場合は、自分のGoogleアカウントをテストユーザーに追加します。
    4. 「認証情報」>「認証情報を作成」>「OAuth クライアント ID」を開き、アプリケーションの種類は iOS を選びます。
    5. Bundle ID は com.rinng.multiview を入力します。
    6. 作成された iOS Client ID をこの画面の「Client ID」に貼り付けます。
    7. Redirect URI は現在「\(redirectURI)」です。これは Client ID 末尾の .apps.googleusercontent.com を com.googleusercontent.apps... に変換して作ります。
    8. その後「ログイン」を押し、YouTubeアカウントで許可します。

    エラー 400: invalid_request が出る場合は、Web/デスクトップ用Client IDを貼っている、Bundle IDが違う、またはRedirect URIが古い multiview:// のまま残っている可能性があります。

    エラー 403: access_denied が出る場合は、OAuth同意画面の公開状態が「テスト」のままです。Google Cloud Consoleの「OAuth同意画面」>「対象」または「テストユーザー」で、この端末でログインするGoogleアカウントを追加してください。

    弾幕取得だけなら youtube.readonly スコープを使います。コメント投稿まで使う場合は、投稿用に広い権限が必要になります。コメントが出ない場合は、配信側のチャット無効、ログイン切れ、Client ID誤り、API未有効化を確認してください。
    """
    let alert = UIAlertController(title: "YouTube Client ID 設定手順", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "認証情報を開く", style: .default) { [weak self] _ in
      self?.openDeveloperURL("https://console.cloud.google.com/apis/credentials")
    })
    alert.addAction(UIAlertAction(title: "閉じる", style: .cancel))
    present(alert, animated: true)
  }

  private func editText(title: String, message: String?, text: String, keyboard: UIKeyboardType, onSave: @escaping (String) -> Void) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addTextField { field in
      field.text = text
      field.keyboardType = keyboard
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
    }
    alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
    alert.addAction(UIAlertAction(title: "保存", style: .default) { _ in
      onSave(alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    })
    present(alert, animated: true)
  }

  private func presentCopiedRedirectAlert(service: String, uri: String, edit: @escaping () -> Void) {
    let alert = UIAlertController(title: "Redirect URI をコピーしました", message: "\(uri)\n\n\(service)のOAuthアプリ設定のCallback/Redirect URIに、この値を登録してください。", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "編集", style: .default) { _ in edit() })
    alert.addAction(UIAlertAction(title: "OK", style: .cancel))
    present(alert, animated: true)
  }

  private func handleNiconicoRow(_ row: Int) {
    if row == 0 {
      // No public OAuth for niconico — log in via the web and persist the cookie.
      present(UINavigationController(rootViewController: NiconicoLoginController()), animated: true)
      return
    }
    guard NiconicoSession.isLoggedIn else { return }
    let alert = UIAlertController(title: "ニコ生からログアウト", message: "保存されたログイン情報(Cookie)を削除します。", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
    alert.addAction(UIAlertAction(title: "ログアウト", style: .destructive) { [weak self] _ in
      NiconicoSession.logout { self?.tableView.reloadData() }
    })
    present(alert, animated: true)
  }

  private func confirmClearWebData() {
    let alert = UIAlertController(
      title: "Webログイン情報と履歴を削除",
      message: "Kick、ニコ生、YouTube、Twitch、ツイキャスのWebView Cookie・閲覧データを削除します。OAuth連携のログイン状態は残します。",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
    alert.addAction(UIAlertAction(title: "削除", style: .destructive) { [weak self] _ in
      WebLoginCookies.clearAll {
        self?.tableView.reloadData()
      }
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
