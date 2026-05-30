import UIKit

// The supported streaming platforms and their per-platform display metadata.
// Extracted from AppDelegate.swift.

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
    case .youtube: return "動画ID / @handle"
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
