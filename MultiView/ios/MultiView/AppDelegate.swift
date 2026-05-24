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
    try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
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

final class NiconicoNativePlayerView: UIView {
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
  private let settings: AppSettings
  private var laneCursor = 0

  init(stream: StreamItem, settings: AppSettings) {
    self.settings = settings
    super.init(frame: .zero)
    backgroundColor = .black

    playerLayer.player = player
    playerLayer.videoGravity = .resizeAspect
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

    load(channel: stream.channel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    player.pause()
    player.replaceCurrentItem(with: nil)
    keepSeatTimer?.invalidate()
    ndgrCommentTask?.cancel()
    segmentTasks.values.forEach { $0.cancel() }
    pageTask?.cancel()
    socketTask?.cancel(with: .goingAway, reason: nil)
    if let itemFailedObserver {
      NotificationCenter.default.removeObserver(itemFailedObserver)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    playerLayer.frame = bounds
    danmakuView.frame = bounds
  }

  private func load(channel: String) {
    let programId = channel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: "https://live.nicovideo.jp/watch/\(programId)") else {
      showStatus("番組IDが不正です")
      return
    }
    var request = URLRequest(url: url)
    request.setValue(NiconicoNativePlayerView.userAgent, forHTTPHeaderField: "User-Agent")
    pageTask = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
      guard let self else { return }
      if let error {
        self.showStatus("ニコ生ページ取得失敗: \(error.localizedDescription)")
        return
      }
      guard let data, let html = String(data: data, encoding: .utf8) else {
        self.showStatus("ニコ生ページを読めません")
        return
      }
      do {
        let watch = try self.parseWatchData(from: html)
        self.connect(webSocketURL: watch.webSocketURL, frontendId: watch.frontendId)
      } catch {
        self.showStatus("ニコ生の再生情報を取得できません")
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
      showStatus("ニコ生WebSocket URLが不正です")
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
          "quality": "abr",
          "protocol": "hls",
          "latency": "low",
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
        self.showStatus("ニコ生WebSocket切断: \(error.localizedDescription)")
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
      play(hlsURL: uri)
    }
    if type == "error",
       let payload = json["data"] as? [String: Any],
       let code = payload["code"] as? String {
      showStatus("ニコ生エラー: \(code)")
    }
    if type == "disconnect" {
      showStatus("ニコ生から切断されました")
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

  private func play(hlsURL: URL) {
    DispatchQueue.main.async {
      self.statusLabel.isHidden = true
      let item = AVPlayerItem(url: hlsURL)
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
      self.player.volume = self.settings.playAudio ? 1 : 0
      self.player.play()
    }
  }

  private func startNDGRComments(viewURI: String) {
    guard settings.showChat else { return }
    ndgrCommentTask?.cancel()
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
          request.setValue(NiconicoNativePlayerView.userAgent, forHTTPHeaderField: "User-Agent")
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

    let video: UIView
    if stream.platform == .niconico {
      video = NiconicoNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else {
      video = PlayerWebView(stream: stream, settings: AppState.shared.settings)
    }
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
      remove.heightAnchor.constraint(equalToConstant: 32)
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
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

    let video: UIView
    if stream.platform == .niconico {
      video = NiconicoNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else {
      video = PlayerWebView(stream: stream, settings: AppState.shared.settings)
    }
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
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
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
