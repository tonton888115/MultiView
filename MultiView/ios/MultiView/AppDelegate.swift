import UIKit
import WebKit
import AVFoundation

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    configureAudioSession()
    window = UIWindow(frame: UIScreen.main.bounds)
    window?.rootViewController = MainTabController()
    window?.makeKeyAndVisible()
    return true
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    configureAudioSession()
  }

  func applicationWillResignActive(_ application: UIApplication) {
    configureAudioSession()
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    configureAudioSession()
  }

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback, options: [])
    try? session.setActive(true)
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

struct AppSettings: Codable {
  var showChat = true
  var proxyUrl = ""
  var playAudio = true
  var layoutMode: LayoutMode = .stacked
  var danmakuFontSize = 20.0
  var danmakuSpeed = 0.13
  var danmakuOpacity = 0.9
  var danmakuMaxLines = 0
  var danmakuMaxLength = 0
  var platformOrder = StreamPlatform.allCases
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
    streams.removeAll { $0.id == stream.id }
  }
}

final class MainTabController: UITabBarController, AppStateDelegate {
  private let viewVC = ViewingController()
  private let rankingVC = RankingController()
  private let followingVC = FollowingController()
  private let settingsVC = SettingsController()

  override func viewDidLoad() {
    super.viewDidLoad()
    AppState.shared.delegate = self
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

  private func glassTabAppearance() -> UITabBarAppearance {
    let appearance = UITabBarAppearance()
    appearance.configureWithDefaultBackground()
    appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
    appearance.backgroundColor = UIColor.black.withAlphaComponent(0.35)
    return appearance
  }
}

final class PlayerWebView: WKWebView {
  init(stream: StreamItem, settings: AppSettings) {
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    if stream.platform == .niconico {
      config.userContentController.addUserScript(WKUserScript(source: PlayerWebView.niconicoPopupBlockerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }
    super.init(frame: .zero, configuration: config)
    isOpaque = false
    backgroundColor = .black
    scrollView.backgroundColor = .black
    scrollView.contentInsetAdjustmentBehavior = .never
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
      URLQueryItem(name: "proxy", value: settings.proxyUrl.trimmingCharacters(in: .whitespacesAndNewlines))
    ]
    if let url = components.url {
      load(URLRequest(url: url))
    }
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

final class MultiPlayerWebView: WKWebView {
  init(streams: [StreamItem], settings: AppSettings) {
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    super.init(frame: .zero, configuration: config)
    isOpaque = false
    backgroundColor = .black
    scrollView.backgroundColor = .black
    scrollView.contentInsetAdjustmentBehavior = .never
    load(streams: streams, settings: settings)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func load(streams: [StreamItem], settings: AppSettings) {
    let encodedStreams = streams
      .map { "\($0.platform.rawValue):\($0.channel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.channel)" }
      .joined(separator: ",")
    var components = URLComponents(string: "https://tonton888115.github.io/MultiView/multiview.html")!
    components.queryItems = [
      URLQueryItem(name: "streams", value: encodedStreams),
      URLQueryItem(name: "layout", value: settings.layoutMode.rawValue),
      URLQueryItem(name: "audio", value: settings.playAudio ? "1" : "0"),
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

  func reload() {
    guard isViewLoaded else { return }
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    let streams = AppState.shared.streams
    if streams.isEmpty {
      stack.addArrangedSubview(emptyView())
      return
    }
    if let focused, streams.contains(focused) {
      stack.addArrangedSubview(FocusedStreamView(stream: focused, onClose: { [weak self] in
        self?.focused = nil
        self?.reload()
      }))
      return
    }
    if streams.contains(where: { $0.platform == .niconico }) {
      addHybridPlayers(streams)
      return
    }
    addUnifiedPlayer(streams)
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
    addCloseBar(streams)
    let web = MultiPlayerWebView(streams: streams, settings: AppState.shared.settings)
    web.translatesAutoresizingMaskIntoConstraints = false
    stack.addArrangedSubview(web)
    web.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor).isActive = true
  }

  private func addHybridPlayers(_ streams: [StreamItem]) {
    let embeddable = streams.filter { $0.platform != .niconico }
    let niconico = streams.filter { $0.platform == .niconico }
    if !embeddable.isEmpty {
      addCloseBar(embeddable)
      let web = MultiPlayerWebView(streams: embeddable, settings: AppState.shared.settings)
      web.translatesAutoresizingMaskIntoConstraints = false
      stack.addArrangedSubview(web)
      let rows = AppState.shared.settings.layoutMode == .grid ? ceil(Double(embeddable.count) / 2.0) : Double(embeddable.count)
      web.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: CGFloat(rows) * 9 / 16).isActive = true
      web.heightAnchor.constraint(greaterThanOrEqualToConstant: embeddable.count == 1 ? 220 : 360).isActive = true
    }
    niconico.forEach { addStackedCell($0) }
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
      let button = UIButton(type: .system)
      button.setTitle("× \(stream.platform.label) / \(stream.channel)", for: .normal)
      button.setTitleColor(.white, for: .normal)
      button.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
      button.contentEdgeInsets = UIEdgeInsets(top: 7, left: 11, bottom: 7, right: 11)
      button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
      button.layer.cornerRadius = 15
      button.addAction(UIAction { _ in AppState.shared.remove(stream) }, for: .touchUpInside)
      row.addArrangedSubview(button)
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
  init(stream: StreamItem, onFocus: @escaping () -> Void) {
    super.init(frame: .zero)
    backgroundColor = .black
    clipsToBounds = true
    layer.cornerRadius = 18
    layer.borderWidth = 0.5
    layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor

    let web = PlayerWebView(stream: stream, settings: AppState.shared.settings)
    web.translatesAutoresizingMaskIntoConstraints = false
    addSubview(web)

    let bar = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.layer.cornerRadius = 14
    bar.clipsToBounds = true
    addSubview(bar)

    let label = UILabel()
    label.text = "● \(stream.platform.label) / \(stream.channel)"
    label.textColor = .white
    label.font = .systemFont(ofSize: 12, weight: .bold)
    label.isUserInteractionEnabled = true
    label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(hideTappedLabel(_:))))
    label.translatesAutoresizingMaskIntoConstraints = false
    bar.contentView.addSubview(label)

    let focus = UIButton(type: .system)
    focus.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right"), for: .normal)
    focus.tintColor = .white
    focus.addAction(UIAction { _ in onFocus() }, for: .touchUpInside)
    focus.translatesAutoresizingMaskIntoConstraints = false
    bar.contentView.addSubview(focus)

    let remove = UIButton(type: .system)
    remove.setImage(UIImage(systemName: "xmark"), for: .normal)
    remove.tintColor = .white
    remove.addAction(UIAction { _ in AppState.shared.remove(stream) }, for: .touchUpInside)
    remove.translatesAutoresizingMaskIntoConstraints = false
    bar.contentView.addSubview(remove)

    NSLayoutConstraint.activate([
      web.topAnchor.constraint(equalTo: topAnchor),
      web.leadingAnchor.constraint(equalTo: leadingAnchor),
      web.trailingAnchor.constraint(equalTo: trailingAnchor),
      web.bottomAnchor.constraint(equalTo: bottomAnchor),
      bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      bar.heightAnchor.constraint(equalToConstant: 36),
      label.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor, constant: 12),
      label.centerYAnchor.constraint(equalTo: bar.contentView.centerYAnchor),
      focus.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
      focus.centerYAnchor.constraint(equalTo: bar.contentView.centerYAnchor),
      remove.leadingAnchor.constraint(equalTo: focus.trailingAnchor, constant: 8),
      remove.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor, constant: -8),
      remove.centerYAnchor.constraint(equalTo: bar.contentView.centerYAnchor),
      focus.widthAnchor.constraint(equalToConstant: 32),
      remove.widthAnchor.constraint(equalToConstant: 32)
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func hideTappedLabel(_ sender: UITapGestureRecognizer) {
    sender.view?.isHidden = true
  }
}

final class FocusedStreamView: UIView {
  private let chatWeb: WKWebView?
  private let input = UITextField()

  init(stream: StreamItem, onClose: (() -> Void)?) {
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

    let video = PlayerWebView(stream: stream, settings: AppState.shared.settings)
    video.translatesAutoresizingMaskIntoConstraints = false
    addSubview(video)

    let bar = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.layer.cornerRadius = 18
    bar.clipsToBounds = true
    addSubview(bar)

    let title = UILabel()
    title.text = "● \(stream.platform.label) / \(stream.channel)"
    title.textColor = .white
    title.font = .systemFont(ofSize: 14, weight: .bold)
    title.isUserInteractionEnabled = true
    title.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(hideTappedLabel(_:))))
    title.translatesAutoresizingMaskIntoConstraints = false
    bar.contentView.addSubview(title)

    var leading = title.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor, constant: 12)
    if let onClose {
      let close = UIButton(type: .system)
      close.setTitle("戻る", for: .normal)
      close.addAction(UIAction { _ in onClose() }, for: .touchUpInside)
      close.translatesAutoresizingMaskIntoConstraints = false
      bar.contentView.addSubview(close)
      leading = title.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 10)
      NSLayoutConstraint.activate([
        close.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor, constant: 12),
        close.centerYAnchor.constraint(equalTo: bar.contentView.centerYAnchor)
      ])
    }

    let remove = UIButton(type: .system)
    remove.setImage(UIImage(systemName: "xmark"), for: .normal)
    remove.tintColor = .white
    remove.addAction(UIAction { _ in AppState.shared.remove(stream) }, for: .touchUpInside)
    remove.translatesAutoresizingMaskIntoConstraints = false
    bar.contentView.addSubview(remove)

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
      bar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      bar.heightAnchor.constraint(equalToConstant: 42),
      leading,
      title.centerYAnchor.constraint(equalTo: bar.contentView.centerYAnchor),
      remove.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
      remove.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor, constant: -12),
      remove.centerYAnchor.constraint(equalTo: bar.contentView.centerYAnchor),
      remove.widthAnchor.constraint(equalToConstant: 32),
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
    if let chatWeb {
      constraints += [
        chatWeb.topAnchor.constraint(equalTo: chatPanel.contentView.topAnchor),
        chatWeb.leadingAnchor.constraint(equalTo: chatPanel.contentView.leadingAnchor),
        chatWeb.trailingAnchor.constraint(equalTo: chatPanel.contentView.trailingAnchor),
        chatWeb.bottomAnchor.constraint(equalTo: chatPanel.contentView.bottomAnchor)
      ]
    }
    NSLayoutConstraint.activate(constraints)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func hideTappedLabel(_ sender: UITapGestureRecognizer) {
    sender.view?.isHidden = true
  }

  private func sendComment() {
    guard let text = input.text, !text.isEmpty, let chatWeb else { return }
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
    .niconico: Source(label: "ニコ生", url: URL(string: "https://ikioi-ranking.com/v/niconama")!, host: "ikioi-ranking.com"),
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
    .niconico: Source(label: "ニコ生", url: URL(string: "https://live.nicovideo.jp/")!, host: "live.nicovideo.jp"),
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

class BrowserSourceController: UIViewController, WKNavigationDelegate {
  private let segmented = UISegmentedControl()
  private let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
  private var activeSources = [(StreamPlatform, Source)]()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)
    web.navigationDelegate = self
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

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if let url = navigationAction.request.url, navigationAction.targetFrame?.isMainFrame != false, let parsed = parseStream(url) {
      AppState.shared.add(platform: parsed.0, channel: parsed.1)
      if let tab = tabBarController {
        tab.selectedIndex = 2
      }
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  private func parseStream(_ url: URL) -> (StreamPlatform, String)? {
    let host = url.host?.replacingOccurrences(of: "www.", with: "").lowercased() ?? ""
    let parts = url.path.split(separator: "/").map(String.init)
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
      return (.niconico, parts[1])
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
    tableView.setEditing(true, animated: false)
  }

  func reload() {
    guard isViewLoaded else { return }
    tableView.reloadData()
  }

  override func numberOfSections(in tableView: UITableView) -> Int { 3 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch section {
    case 0: return 9
    case 1: return platforms.count
    default: return 1
    }
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    switch section {
    case 0: return "視聴"
    case 1: return "サービス順"
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
      cell.textLabel?.text = "CORSプロキシ"
      cell.detailTextLabel?.text = nil
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    } else if indexPath.section == 0 {
      let slider = UISlider()
      slider.frame = CGRect(x: 0, y: 0, width: 150, height: 32)
      slider.tag = indexPath.row
      slider.addAction(UIAction { [weak self] action in
        guard let slider = action.sender as? UISlider else { return }
        self?.updateDanmakuSetting(row: slider.tag, value: slider.value)
      }, for: .valueChanged)
      switch indexPath.row {
      case 4:
        cell.textLabel?.text = "文字サイズ \(Int(AppState.shared.settings.danmakuFontSize))"
        slider.minimumValue = 12
        slider.maximumValue = 40
        slider.value = Float(AppState.shared.settings.danmakuFontSize)
      case 5:
        cell.textLabel?.text = "速度 \(Int((AppState.shared.settings.danmakuSpeed / 0.13) * 100))%"
        slider.minimumValue = 0.05
        slider.maximumValue = 0.3
        slider.value = Float(AppState.shared.settings.danmakuSpeed)
      case 6:
        cell.textLabel?.text = "透過度 \(Int(AppState.shared.settings.danmakuOpacity * 100))%"
        slider.minimumValue = 0.3
        slider.maximumValue = 1
        slider.value = Float(AppState.shared.settings.danmakuOpacity)
      case 7:
        cell.textLabel?.text = "最大行数 \(AppState.shared.settings.danmakuMaxLines == 0 ? "自動" : String(AppState.shared.settings.danmakuMaxLines))"
        slider.minimumValue = 0
        slider.maximumValue = 20
        slider.value = Float(AppState.shared.settings.danmakuMaxLines)
      default:
        cell.textLabel?.text = "最大文字数 \(AppState.shared.settings.danmakuMaxLength == 0 ? "無制限" : String(AppState.shared.settings.danmakuMaxLength))"
        slider.minimumValue = 0
        slider.maximumValue = 200
        slider.value = Float(AppState.shared.settings.danmakuMaxLength)
      }
      cell.accessoryView = slider
    } else if indexPath.section == 1 {
      let platform = platforms[indexPath.row]
      cell.textLabel?.text = platform.label
    } else {
      cell.textLabel?.text = "配信を手動追加"
      cell.accessoryType = .disclosureIndicator
      cell.selectionStyle = .default
    }
    return cell
  }

  override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
    indexPath.section == 1
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
    if indexPath.section == 0 && indexPath.row == 3 {
      editProxy()
    } else if indexPath.section == 2 {
      present(AddStreamController(), animated: true)
    }
  }

  private func updateDanmakuSetting(row: Int, value: Float) {
    var settings = AppState.shared.settings
    switch row {
    case 4:
      settings.danmakuFontSize = Double(round(value))
    case 5:
      settings.danmakuSpeed = Double(value)
    case 6:
      settings.danmakuOpacity = Double(value)
    case 7:
      settings.danmakuMaxLines = Int(round(value))
    case 8:
      settings.danmakuMaxLength = Int(round(value / 10) * 10)
    default:
      return
    }
    AppState.shared.settings = settings
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
