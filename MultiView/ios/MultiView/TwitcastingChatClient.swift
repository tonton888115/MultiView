import Foundation
import WebKit

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

  private static let userAgent = BrowserUserAgent.mobileSafari
}
