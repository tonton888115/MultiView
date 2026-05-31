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
  private var lastResumeAllAt = Date.distantPast

  func register(_ view: PlaybackResumable) {
    views.add(view as AnyObject)
  }

  func resumeAll() {
    // 同一ランループ内の重複呼び出し(reload/viewDidAppear/各リトライが重なる)を間引く。
    // リトライ間隔(0.2s〜)より十分短い 0.15s なので、意図的な再試行は阻害しない。
    let now = Date()
    guard now.timeIntervalSince(lastResumeAllAt) > 0.15 else { return }
    lastResumeAllAt = now
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

  // 自動適応(Codex案): 同時視聴が3本以上だと帯域不足でカクつくため、ビットレート上限を
  // 自動でエコノミー(約900kbps)へ落とす。2本以下は設定どおりの画質。
  func effectivePeakBitRate(settings: AppSettings) -> Double {
    let base = activeQuality(settings: settings).preferredPeakBitRate
    guard settings.autoEconomyOnManyStreams, AppState.shared.streams.count >= 3 else { return base }
    let economy = PlaybackQuality.economy.preferredPeakBitRate
    return base == 0 ? economy : min(base, economy)
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
      // 再生/並び順/チャット接続に影響する設定が変わった時だけプレイヤー等を作り直す。
      // 弾幕表示・ギフト通知の種別・ギフト音などの表示系トグルはイベント時に live で読むので
      // reload 不要＝トグルのたびに再生が無駄に作り直されない(Codex指摘 #5)。
      let needsReload = settings.wifiQuality != oldValue.wifiQuality
        || settings.mobileQuality != oldValue.mobileQuality
        || settings.niconicoLowLatency != oldValue.niconicoLowLatency
        || settings.playAudio != oldValue.playAudio
        || settings.showChat != oldValue.showChat
        || settings.layoutMode != oldValue.layoutMode
        || settings.platformOrder != oldValue.platformOrder
        || settings.autoEconomyOnManyStreams != oldValue.autoEconomyOnManyStreams
      if needsReload {
        delegate?.appStateDidChange()
      }
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

// Viewing UI (grid + focused single-stream) is defined in ViewingUI.swift.

// Browse (ranking/following), Niconico login, Settings and AddStream screens are defined in Screens.swift.
