import UIKit
import WebKit
import AVFoundation
import Network
import ImageIO
import AuthenticationServices
import Security
import CryptoKit

// Source-browser screens (Ranking/Following + shared BrowserSourceController), the
// Niconico web-login screen, Settings, and the Add-Stream screen. From AppDelegate.swift.

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
    case .playback: return 12
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
      case 4:
        cell.textLabel?.text = "モバイル通信時の画質"
        cell.accessoryView = qualityControl(selected: AppState.shared.settings.mobileQuality) { quality in
          var s = AppState.shared.settings; s.mobileQuality = quality; AppState.shared.settings = s
        }
      case 5:
        cell.textLabel?.text = "ニコ生 低遅延 (カクつくことがあります)"
        cell.accessoryView = switchControl(isOn: AppState.shared.settings.niconicoLowLatency) { v in
          var s = AppState.shared.settings; s.niconicoLowLatency = v; AppState.shared.settings = s
        }
      case 6:
        cell.textLabel?.text = "ギフト通知音"
        cell.accessoryView = switchControl(isOn: AppState.shared.settings.giftSoundEnabled) { v in
          var s = AppState.shared.settings; s.giftSoundEnabled = v; AppState.shared.settings = s
        }
      case 7:
        cell.textLabel?.text = "ニコ生 ギフト通知を表示"
        cell.accessoryView = switchControl(isOn: AppState.shared.settings.niconicoShowGift) { v in
          var s = AppState.shared.settings; s.niconicoShowGift = v; AppState.shared.settings = s
        }
      case 8:
        cell.textLabel?.text = "ニコ生 ニコニ広告を表示"
        cell.accessoryView = switchControl(isOn: AppState.shared.settings.niconicoShowNicoad) { v in
          var s = AppState.shared.settings; s.niconicoShowNicoad = v; AppState.shared.settings = s
        }
      case 9:
        cell.textLabel?.text = "ニコ生 お知らせ通知を表示"
        cell.accessoryView = switchControl(isOn: AppState.shared.settings.niconicoShowNotification) { v in
          var s = AppState.shared.settings; s.niconicoShowNotification = v; AppState.shared.settings = s
        }
      case 10:
        cell.textLabel?.text = "タップ時に同接数を左下に表示"
        cell.accessoryView = switchControl(isOn: AppState.shared.settings.showViewerCount) { v in
          var s = AppState.shared.settings; s.showViewerCount = v; AppState.shared.settings = s
        }
      default:
        cell.textLabel?.text = "3本以上で自動エコノミー画質"
        cell.accessoryView = switchControl(isOn: AppState.shared.settings.autoEconomyOnManyStreams) { v in
          var s = AppState.shared.settings; s.autoEconomyOnManyStreams = v; AppState.shared.settings = s
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
