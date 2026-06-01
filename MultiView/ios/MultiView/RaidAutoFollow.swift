import Foundation

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
