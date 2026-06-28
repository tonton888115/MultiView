import UIKit
import WebKit
import AVFoundation

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  // Set when another app/video interrupts our audio session. When we regain
  // control we rebuild the players (auto-refresh) instead of only nudging play,
  // because embedded players often stay paused after a takeover.
  private var needsPlaybackReload = false
  private var authMaintenanceTimer: Timer?

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
    maintainOAuthSessions()
    authMaintenanceTimer?.invalidate()
    authMaintenanceTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
      KickAuthManager.shared.maintainSession()
      TwitchAuthManager.shared.maintainSession()
      YouTubeAuthManager.shared.maintainSession()
    }
    // Pull any fresh web-view logins into the native cookie jar.
    WebLoginCookies.sync()
    if needsPlaybackReload {
      needsPlaybackReload = false
      reloadAndResumeSoon()
    } else {
      resumePlaybackSoon()
    }
  }

  func applicationWillResignActive(_ application: UIApplication) {
    authMaintenanceTimer?.invalidate()
    authMaintenanceTimer = nil
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

  private func maintainOAuthSessions() {
    KickAuthManager.shared.maintainSession()
    TwitchAuthManager.shared.maintainSession()
    YouTubeAuthManager.shared.maintainSession()
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

// OAuth managers / configs / keychain / live-chat DTOs are defined in OAuth.swift.
// App state and persistence are defined in AppState.swift.

final class MainTabController: UITabBarController, UITabBarControllerDelegate, AppStateDelegate {
  private let viewVC = ViewingController()
  private let rankingVC = RankingController()
  private let followingVC = FollowingController()
  private let settingsVC = SettingsController()

  override func viewDidLoad() {
    super.viewDidLoad()
    AppState.shared.delegate = self
    delegate = self
    configureIPadTabPlacement()
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

  func appStateStreamsDidChange() {
    // 並び順・本数だけの変化。視聴タブはプレイヤーを再利用して更新(並び替えはアニメ)。
    // ランキング/フォロー/設定は platformOrder(=settings)依存なので、ここでは更新しない。
    viewVC.reloadForStreamsChange()
  }

  func appStateSettingsDidChange() {
    // 画質・弾幕・レイアウト等。プレイヤーへ確実に反映するため作り直す。
    viewVC.reload(rebuildPlayers: true)
    rankingVC.reloadOrder()
    followingVC.reloadOrder()
    settingsVC.reload()
  }

  @objc private func raidFollowed() {
    // streams への追加は appStateStreamsDidChange 経由で視聴タブへ既に反映される。
    // ここではレイドで増えた配信を見せるため視聴タブへ切り替えるだけ。
    selectedIndex = 2
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

  func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
    if tabBarController.selectedViewController !== viewController {
      (tabBarController.selectedViewController as? BrowserSourceController)?.resetForTabExit()
    }
    return true
  }

  private func configureIPadTabPlacement() {
    guard UIDevice.current.userInterfaceIdiom == .pad else { return }
    #if compiler(>=6.0)
    if #available(iOS 18.0, *) {
      mode = .tabBar
    }
    #endif
    #if compiler(>=5.9)
    if #available(iOS 17.0, *) {
      traitOverrides.horizontalSizeClass = .compact
    }
    #endif
  }

  private func glassTabAppearance() -> UITabBarAppearance {
    let appearance = UITabBarAppearance()
    appearance.configureWithDefaultBackground()
    appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
    appearance.backgroundColor = UIColor.black.withAlphaComponent(0.35)
    return appearance
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
  private var reloadAttempt = 0
  private var reloadWorkItem: DispatchWorkItem?

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
    } else if stream.platform == .kick || stream.platform == .twitch {
      config.userContentController.addUserScript(WKUserScript(source: PlayerWebView.embeddedPlayerTouchShieldScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
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
      let programId = stream.channel.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let escaped = programId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "https://live.nicovideo.jp/watch/\(escaped)") else {
        loadHTMLString("<html><body style=\"background:#000;color:#fff;font-family:-apple-system;padding:16px\">ニコ生番組IDが不正です</body></html>", baseURL: nil)
        return
      }
      var request = URLRequest(url: url)
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
    reloadWorkItem?.cancel()
    reloadWorkItem = nil
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
    reloadAttempt = 0
    reloadWorkItem?.cancel()
    reloadWorkItem = nil
    startTwitcastingChatIfNeeded()
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    scheduleReload(after: error)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    scheduleReload(after: error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    scheduleReload(after: nil)
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if (stream.platform == .kick || stream.platform == .twitch),
       navigationAction.navigationType == .linkActivated {
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  private func startTwitcastingChatIfNeeded() {
    guard stream.platform == .twitcasting, showChat, !twitcastingStarted else { return }
    twitcastingStarted = true
    twitcastingChat = TwitcastingChatClient(channel: stream.channel) { [weak self] message, user in
      self?.emitComment(message, user)
    }
  }

  private func scheduleReload(after error: Error?) {
    guard !isStopped, reloadWorkItem == nil else { return }
    if let error = error as? URLError, error.code == .cancelled { return }
    let delays: [TimeInterval] = [1, 2, 5, 10, 20, 30]
    let delay = delays[min(reloadAttempt, delays.count - 1)]
    reloadAttempt += 1
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.isStopped else { return }
      self.reloadWorkItem = nil
      self.reloadFromOrigin()
    }
    reloadWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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

  private static let embeddedPlayerTouchShieldScript = """
  (function(){
    var styleId = 'mv-embedded-player-touch-shield';
    function install(){
      if (!document.getElementById(styleId)) {
        var style = document.createElement('style');
        style.id = styleId;
        style.textContent = '#player iframe,#player video{pointer-events:none!important}';
        (document.head || document.documentElement).appendChild(style);
      }
    }
    install();
    new MutationObserver(install).observe(document.documentElement, { childList:true, subtree:true });
  })();
  """

  private static let mobileSafariUserAgent = BrowserUserAgent.mobileSafari

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
