import UIKit

final class ViewerCountOverlay: UIVisualEffectView {
  private let stream: StreamItem
  private let label = UILabel()
  private var timer: Timer?
  private var task: URLSessionDataTask?

  init(stream: StreamItem) {
    self.stream = stream
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      super.init(effect: UIGlassEffect())
    } else {
      super.init(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    }
    #else
    super.init(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    #endif
    isHidden = true
    alpha = 0
    isUserInteractionEnabled = false
    clipsToBounds = true
    layer.cornerRadius = 12
    contentView.isUserInteractionEnabled = false

    let icon = UIImageView(image: UIImage(systemName: "eye.fill"))
    icon.tintColor = .white
    icon.contentMode = .scaleAspectFit
    icon.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(icon)

    label.font = .systemFont(ofSize: 12, weight: .bold)
    label.textColor = .white
    label.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(label)

    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
      icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 14),
      icon.heightAnchor.constraint(equalToConstant: 14),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
      label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
      label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
      label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5)
    ])

    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      self?.refresh()
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    timer?.invalidate()
    task?.cancel()
  }

  private func refresh() {
    task?.cancel()
    task = ViewerCountProvider.fetch(stream: stream) { [weak self] count in
      DispatchQueue.main.async {
        self?.apply(count: count)
      }
    }
  }

  private func apply(count: Int?) {
    guard let count, count >= 0 else {
      UIView.animate(withDuration: 0.16) {
        self.alpha = 0
      } completion: { _ in
        self.isHidden = true
      }
      return
    }
    let controlsAreVisible = alpha > 0.01
    label.text = "\(count)人"
    accessibilityLabel = "同接 \(count)人"
    if isHidden {
      isHidden = false
    }
    guard controlsAreVisible else {
      alpha = 0
      return
    }
    UIView.animate(withDuration: 0.16) {
      self.alpha = 1
    }
  }
}

enum ViewerCountProvider {
  static func fetch(stream: StreamItem, completion: @escaping (Int?) -> Void) -> URLSessionDataTask? {
    switch stream.platform {
    case .kick:
      return fetchKick(channel: stream.channel, completion: completion)
    case .twitch:
      return fetchTwitch(channel: stream.channel, completion: completion)
    case .twitcasting:
      return fetchTwitcasting(channel: stream.channel, completion: completion)
    case .youtube:
      return fetchYouTube(channel: stream.channel, completion: completion)
    case .niconico:
      return fetchNiconico(programId: stream.channel, completion: completion)
    }
  }

  private static func fetchKick(channel rawChannel: String, completion: @escaping (Int?) -> Void) -> URLSessionDataTask? {
    let channel = normalizedChannel(rawChannel)
    guard let escaped = channel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          let url = URL(string: "https://kick.com/api/v2/channels/\(escaped)") else {
      completion(nil)
      return nil
    }
    return jsonTask(url: url, headers: browserHeaders(referer: "https://kick.com/\(channel)")) { object in
      let live = (object as? [String: Any])?["livestream"] as? [String: Any]
      completion(live.flatMap { count(in: $0, keys: kickKeys) })
    }
  }

  private static func fetchTwitch(channel rawChannel: String, completion: @escaping (Int?) -> Void) -> URLSessionDataTask? {
    let channel = normalizedChannel(rawChannel).lowercased()
    guard let url = URL(string: "https://gql.twitch.tv/gql") else {
      completion(nil)
      return nil
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("kimne78kx3ncx6brgo4mv6wki5h1ko", forHTTPHeaderField: "Client-ID")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "operationName": "ViewerCount",
      "variables": ["login": channel],
      "query": "query ViewerCount($login: String!) { user(login: $login) { stream { viewersCount } } }"
    ])
    let task = URLSession.shared.dataTask(with: request) { data, _, _ in
      guard let object = parseJSON(data),
            let dataDict = (object as? [String: Any])?["data"] as? [String: Any],
            let user = dataDict["user"] as? [String: Any],
            let stream = user["stream"] as? [String: Any] else {
        completion(nil)
        return
      }
      completion(intValue(stream["viewersCount"]))
    }
    task.resume()
    return task
  }

  private static func fetchTwitcasting(channel rawChannel: String, completion: @escaping (Int?) -> Void) -> URLSessionDataTask? {
    let channel = normalizedChannel(rawChannel)
    guard let escaped = channel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          let url = URL(string: "https://twitcasting.tv/\(escaped)") else {
      completion(nil)
      return nil
    }
    var headers = browserHeaders(referer: "https://twitcasting.tv/")
    headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    return htmlTask(url: url, headers: headers) { html in
      guard let viewerURL = twitcastingViewerURL(from: html) else {
        completion(nil)
        return
      }
      _ = jsonTask(url: viewerURL, headers: browserHeaders(referer: "https://twitcasting.tv/\(channel)")) { object in
        completion(twitcastingViewerCount(from: object))
      }
    }
  }

  private static func fetchYouTube(channel rawChannel: String, completion: @escaping (Int?) -> Void) -> URLSessionDataTask? {
    let channel = rawChannel.trimmingCharacters(in: .whitespacesAndNewlines)
    if let videoId = extractYouTubeVideoID(from: channel) {
      return fetchYouTubePlayer(videoId: videoId, fallbackHTML: nil, fallbackURL: youtubeWatchURL(videoId: videoId), completion: completion)
    }
    guard let liveURL = youtubeLiveURL(from: channel) else {
      completion(nil)
      return nil
    }
    var request = URLRequest(url: liveURL)
    browserHeaders(referer: "https://www.youtube.com/").forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    let task = URLSession.shared.dataTask(with: request) { data, _, _ in
      guard let html = data.flatMap({ String(data: $0, encoding: .utf8) }),
            let videoId = extractYouTubeVideoID(from: html) else {
        completion(nil)
        return
      }
      if let count = youtubeCount(inHTML: html) {
        completion(count)
        return
      }
      _ = fetchYouTubePlayer(videoId: videoId, fallbackHTML: html, fallbackURL: youtubeWatchURL(videoId: videoId), completion: completion)
    }
    task.resume()
    return task
  }

  private static func fetchNiconico(programId rawProgramId: String, completion: @escaping (Int?) -> Void) -> URLSessionDataTask? {
    guard let programId = extractNiconicoProgramID(from: rawProgramId) else {
      completion(nil)
      return nil
    }
    guard let url = URL(string: "https://live.nicovideo.jp/watch/\(programId)") else {
      completion(nil)
      return nil
    }
    return htmlTask(url: url, headers: browserHeaders(referer: "https://live.nicovideo.jp/")) { html in
      guard let props = niconicoProps(from: html) else {
        completion(niconicoViewerCount(fromHTML: html))
        return
      }
      completion(niconicoViewerCount(from: props) ?? niconicoViewerCount(fromHTML: html))
    }
  }

  private static func fetchYouTubePlayer(
    videoId: String,
    fallbackHTML: String?,
    fallbackURL: URL?,
    completion: @escaping (Int?) -> Void
  ) -> URLSessionDataTask? {
    guard let url = URL(string: "https://youtubei.googleapis.com/youtubei/v1/player") else {
      completion(nil)
      return nil
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(BrowserUserAgent.youtubeIOS(version: BrowserUserAgent.youtubeIOSVersion), forHTTPHeaderField: "User-Agent")
    request.setValue("5", forHTTPHeaderField: "X-YouTube-Client-Name")
    request.setValue(BrowserUserAgent.youtubeIOSVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "context": [
        "client": [
          "clientName": "IOS",
              "clientVersion": BrowserUserAgent.youtubeIOSVersion,
          "deviceMake": "Apple",
          "deviceModel": "iPhone16,2",
          "osName": "iOS",
          "osVersion": "17.5.1.21F90",
          "hl": "ja",
          "gl": "JP"
        ]
      ],
      "videoId": videoId,
      "contentCheckOk": true,
      "racyCheckOk": true
    ])
    let task = URLSession.shared.dataTask(with: request) { data, _, _ in
      let object = parseJSON(data)
      if let count = youtubeCount(in: object) {
        completion(count)
        return
      }
      if let count = youtubeCount(inHTML: fallbackHTML) {
        completion(count)
        return
      }
      guard let fallbackURL else {
        completion(nil)
        return
      }
      _ = htmlTask(url: fallbackURL, headers: browserHeaders(referer: "https://www.youtube.com/")) { html in
        completion(youtubeCount(inHTML: html))
      }
    }
    task.resume()
    return task
  }

  private static func jsonTask(url: URL, headers: [String: String], completion: @escaping (Any?) -> Void) -> URLSessionDataTask {
    var request = URLRequest(url: url)
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    let task = URLSession.shared.dataTask(with: request) { data, _, _ in
      completion(parseJSON(data))
    }
    task.resume()
    return task
  }

  private static func htmlTask(url: URL, headers: [String: String], completion: @escaping (String?) -> Void) -> URLSessionDataTask {
    var request = URLRequest(url: url)
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    let task = URLSession.shared.dataTask(with: request) { data, _, _ in
      completion(data.flatMap { String(data: $0, encoding: .utf8) })
    }
    task.resume()
    return task
  }

  private static func count(in value: Any?, keys: Set<String>) -> Int? {
    guard let value else { return nil }
    if let dict = value as? [String: Any] {
      for (key, nested) in dict where keys.contains(key) {
        if let count = intValue(nested) { return count }
      }
      for nested in dict.values {
        if let count = count(in: nested, keys: keys) { return count }
      }
    } else if let array = value as? [Any] {
      for nested in array {
        if let count = count(in: nested, keys: keys) { return count }
      }
    }
    return nil
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? Double, value.isFinite { return Int(value) }
    if let value = value as? String {
      let normalized = value
        .replacingOccurrences(of: ",", with: "")
        .replacingOccurrences(of: "人", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return Int(normalized)
    }
    return nil
  }

  private static func parseJSON(_ data: Data?) -> Any? {
    guard let data else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }

  private static func normalizedChannel(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    value = value.replacingOccurrences(of: "^[@#]+", with: "", options: .regularExpression)
    if let range = value.range(of: "twitch.tv/", options: .caseInsensitive) {
      value = String(value[range.upperBound...])
    }
    if let range = value.range(of: "kick.com/", options: .caseInsensitive) {
      value = String(value[range.upperBound...])
    }
    if let range = value.range(of: "twitcasting.tv/", options: .caseInsensitive) {
      value = String(value[range.upperBound...])
    }
    value = value.components(separatedBy: CharacterSet(charactersIn: "/?# \n\t.,)」]")).first ?? value
    return value
  }

  private static func extractYouTubeVideoID(from raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil {
      return trimmed
    }
    let patterns = [
      #"(?:\?|&)v=([A-Za-z0-9_-]{11})"#,
      #"youtu\.be/([A-Za-z0-9_-]{11})"#,
      #"/live/([A-Za-z0-9_-]{11})"#,
      #"/embed/([A-Za-z0-9_-]{11})"#,
      #""videoId"\s*:\s*"([A-Za-z0-9_-]{11})""#,
      #""video_id"\s*:\s*"([A-Za-z0-9_-]{11})""#,
      #"<link[^>]+rel=["']canonical["'][^>]+href=["']https://www\.youtube\.com/watch\?v=([A-Za-z0-9_-]{11})"#
    ]
    for pattern in patterns {
      if let value = firstMatch(in: trimmed, pattern: pattern) { return value }
    }
    return nil
  }

  private static func youtubeLiveURL(from raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("@") {
      let handle = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
      return URL(string: "https://www.youtube.com/\(handle)/live")
    }
    if trimmed.contains("youtube.com/") || trimmed.contains("youtu.be/") {
      return URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
    }
    let handle = trimmed.replacingOccurrences(of: "^@+", with: "", options: .regularExpression)
    return URL(string: "https://www.youtube.com/@\(handle)/live")
  }

  private static func youtubeWatchURL(videoId: String) -> URL? {
    URL(string: "https://www.youtube.com/watch?v=\(videoId)")
  }

  private static func extractNiconicoProgramID(from raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let patterns = [
      #"live\.nicovideo\.jp/watch/(lv[0-9]+)"#,
      #"(lv[0-9]{6,})"#
    ]
    for pattern in patterns {
      if let value = firstMatch(in: trimmed, pattern: pattern) { return value }
    }
    let channel = normalizedChannel(trimmed)
    return channel.range(of: #"^lv[0-9]{6,}$"#, options: .regularExpression) != nil ? channel : nil
  }

  private static func niconicoProps(from html: String?) -> Any? {
    guard let html,
          let encoded = firstMatch(in: html, pattern: #"<script[^>]+id=["']initial-state["'][^>]+data-props=["']([^"']+)["']"#)
            ?? firstMatch(in: html, pattern: #"data-props=["']([^"']+)["'][^>]+id=["']initial-state["']"#)
            ?? firstMatch(in: html, pattern: #"<script[^>]+id=["']embedded-data["'][^>]+data-props=["']([^"']+)["']"#)
            ?? firstMatch(in: html, pattern: #"data-props=["']([^"']+)["'][^>]+id=["']embedded-data["']"#) else {
      return nil
    }
    let decoded = decodeHTMLEntities(encoded)
    return parseJSON(decoded.data(using: .utf8))
  }

  private static func niconicoViewerCount(from value: Any?) -> Int? {
    count(in: value, keys: niconicoKeys)
  }

  private static func niconicoViewerCount(fromHTML html: String?) -> Int? {
    guard let html else { return nil }
    let decoded = decodeHTMLEntities(html)
    let patterns = [
      #""currentViewers"\s*:\s*"?([0-9,]+)"?"#,
      #""currentViewerCount"\s*:\s*"?([0-9,]+)"?"#,
      #""current_viewers"\s*:\s*"?([0-9,]+)"?"#,
      #""current_viewer_count"\s*:\s*"?([0-9,]+)"?"#,
      #""viewersCount"\s*:\s*"?([0-9,]+)"?"#,
      #""viewerCount"\s*:\s*"?([0-9,]+)"?"#
    ]
    for pattern in patterns {
      if let value = firstMatch(in: decoded, pattern: pattern) {
        return intValue(value)
      }
    }
    return nil
  }

  private static func youtubeCount(in value: Any?) -> Int? {
    guard let value else { return nil }
    if let dict = value as? [String: Any] {
      if let details = dict["videoDetails"] as? [String: Any],
         let count = intValue(details["concurrentViewers"]) {
        return count
      }
      if let microformat = dict["microformat"] as? [String: Any],
         let renderer = microformat["playerMicroformatRenderer"] as? [String: Any],
         let live = renderer["liveBroadcastDetails"] as? [String: Any],
         let count = intValue(live["concurrentViewers"]) {
        return count
      }
    }
    return youtubePrimaryViewerCount(in: value) ?? count(in: value, keys: youtubeKeys)
  }

  private static func youtubeCount(inHTML html: String?) -> Int? {
    guard let html else { return nil }
    let decoded = decodeHTMLEntities(html)
    let patterns = [
      #""concurrentViewers"\s*:\s*"?([0-9,]+)"?"#
    ]
    for pattern in patterns {
      if let value = firstMatch(in: decoded, pattern: pattern) {
        return intValue(value)
      }
    }
    for token in ["ytInitialPlayerResponse", "ytInitialData"] {
      guard let json = jsonObjectString(afterToken: token, in: decoded),
            let object = parseJSON(json.data(using: .utf8)),
            let count = youtubeCount(in: object) else { continue }
      return count
    }
    return nil
  }

  private static func youtubePrimaryViewerCount(in value: Any?) -> Int? {
    guard let root = value as? [String: Any],
          let contentsRoot = root["contents"] as? [String: Any],
          let twoColumn = contentsRoot["twoColumnWatchNextResults"] as? [String: Any],
          let results = twoColumn["results"] as? [String: Any],
          let nestedResults = results["results"] as? [String: Any],
          let contents = nestedResults["contents"] as? [[String: Any]] else {
      return nil
    }
    for item in contents {
      guard let primary = item["videoPrimaryInfoRenderer"] as? [String: Any],
            let viewCount = primary["viewCount"] as? [String: Any],
            let renderer = viewCount["videoViewCountRenderer"] as? [String: Any],
            let count = youtubeVideoViewCountRendererCount(renderer) else {
        continue
      }
      return count
    }
    return nil
  }

  private static func youtubeVideoViewCountRendererCount(_ renderer: [String: Any]) -> Int? {
    guard let isLive = renderer["isLive"] as? Bool, isLive else { return nil }
    return intValue(renderer["originalViewCount"])
  }

  private static func jsonObjectString(afterToken token: String, in text: String) -> String? {
    var searchRange = text.startIndex..<text.endIndex
    while let tokenRange = text.range(of: token, range: searchRange),
          let start = text[tokenRange.upperBound...].firstIndex(of: "{") {
      var index = start
      var depth = 0
      var inString = false
      var escaping = false
      while index < text.endIndex {
        let character = text[index]
        if inString {
          if escaping {
            escaping = false
          } else if character == "\\" {
            escaping = true
          } else if character == "\"" {
            inString = false
          }
        } else if character == "\"" {
          inString = true
        } else if character == "{" {
          depth += 1
        } else if character == "}" {
          depth -= 1
          if depth == 0 {
            return String(text[start...index])
          }
        }
        index = text.index(after: index)
      }
      searchRange = tokenRange.upperBound..<text.endIndex
    }
    return nil
  }

  private static func twitcastingViewerURL(from html: String?) -> URL? {
    guard let html else { return nil }
    let decoded = decodeHTMLEntities(html)
    let patterns = [
      #"fetch\(["']([^"']*userajax\.php\?c=viewers[^"']+)["']\)"#,
      #"["']([^"']*userajax\.php\?c=viewers[^"']+)["']"#
    ]
    for pattern in patterns {
      guard let raw = firstMatch(in: decoded, pattern: pattern) else { continue }
      if let absolute = URL(string: raw), absolute.scheme != nil {
        return absolute
      }
      let path = raw.hasPrefix("/") ? raw : "/\(raw)"
      if let url = URL(string: "https://twitcasting.tv\(path)") {
        return url
      }
      if let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        return URL(string: "https://twitcasting.tv\(encodedPath)")
      }
    }
    return nil
  }

  private static func twitcastingViewerCount(from object: Any?) -> Int? {
    if let array = object as? [Any], let first = array.first {
      return intValue(first)
    }
    if let dict = object as? [String: Any] {
      if let data = dict["data"] as? [Any], let first = data.first {
        return intValue(first)
      }
      if let viewers = dict["viewers"] as? [Any], let first = viewers.first {
        return intValue(first)
      }
    }
    return count(in: object, keys: twitcastingKeys)
  }

  private static func firstMatch(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
          let valueRange = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[valueRange])
  }

  private static func decodeHTMLEntities(_ text: String) -> String {
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

  private static func browserHeaders(referer: String) -> [String: String] {
    [
      "Accept": "application/json, text/plain, */*",
      "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6",
      "Referer": referer,
      "User-Agent": userAgent
    ]
  }

  private static let userAgent = BrowserUserAgent.mobileSafari
  private static let kickKeys: Set<String> = ["viewer_count", "viewerCount", "viewers", "viewersCount", "currentViewers"]
  private static let twitcastingKeys: Set<String> = ["current_view_count", "currentViewerCount", "current_viewer_count", "viewer_count", "viewerCount", "viewers"]
  private static let youtubeKeys: Set<String> = ["concurrentViewers", "concurrent_viewers"]
  private static let niconicoKeys: Set<String> = ["currentViewers", "currentViewerCount", "current_viewers", "current_viewer_count", "viewersCount", "viewerCount"]
}
