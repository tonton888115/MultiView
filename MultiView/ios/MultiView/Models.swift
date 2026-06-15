import Foundation

// Core value types: a stream entry, layout mode, playback quality, and the
// persisted app settings. Extracted from AppDelegate.swift.

struct StreamItem: Codable, Equatable {
  let id: String
  let platform: StreamPlatform
  let channel: String
}

enum LayoutMode: String, Codable {
  case stacked
  case grid
}

enum PlaybackQuality: String, Codable {
  case high
  case economy

  var label: String {
    switch self {
    case .high: return "高画質"
    case .economy: return "エコノミー"
    }
  }

  var preferredPeakBitRate: Double {
    switch self {
    case .high: return 0
    case .economy: return 900_000
    }
  }

  var niconicoQuality: String {
    switch self {
    case .high: return "abr"
    case .economy: return "low"
    }
  }
}

struct AppSettings: Codable {
  var settingsVersion = 3
  var showChat = true
  var showViewerCount = true
  var playAudio = true
  var autoFollowRaids = false
  var blockWebAds = true
  var layoutMode: LayoutMode = .stacked
  var wifiQuality: PlaybackQuality = .high
  var mobileQuality: PlaybackQuality = .economy
  var danmakuFontSize = 20.0
  var danmakuSpeed = 0.13
  var danmakuOpacity = 0.9
  var danmakuMaxLines = 0
  var danmakuMaxLength = 0
  var niconicoLowLatency = false
  var showGiftEffects = true
  var giftSoundEnabled = true
  var niconicoShowGift = true
  var niconicoShowNicoad = true
  var niconicoShowNotification = true
  var autoEconomyOnManyStreams = true
  var platformOrder = StreamPlatform.allCases

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSettingsVersion = try container.decodeIfPresent(Int.self, forKey: .settingsVersion) ?? 0
    settingsVersion = 3
    showChat = try container.decodeIfPresent(Bool.self, forKey: .showChat) ?? true
    let decodedShowViewerCount = try container.decodeIfPresent(Bool.self, forKey: .showViewerCount)
    showViewerCount = decodedShowViewerCount == false && decodedSettingsVersion >= 3 ? false : decodedShowViewerCount ?? true
    playAudio = try container.decodeIfPresent(Bool.self, forKey: .playAudio) ?? true
    autoFollowRaids = try container.decodeIfPresent(Bool.self, forKey: .autoFollowRaids) ?? false
    blockWebAds = try container.decodeIfPresent(Bool.self, forKey: .blockWebAds) ?? true
    layoutMode = try container.decodeIfPresent(LayoutMode.self, forKey: .layoutMode) ?? .stacked
    wifiQuality = try container.decodeIfPresent(PlaybackQuality.self, forKey: .wifiQuality) ?? .high
    mobileQuality = try container.decodeIfPresent(PlaybackQuality.self, forKey: .mobileQuality) ?? .economy
    danmakuFontSize = try container.decodeIfPresent(Double.self, forKey: .danmakuFontSize) ?? 20
    danmakuSpeed = try container.decodeIfPresent(Double.self, forKey: .danmakuSpeed) ?? 0.13
    danmakuOpacity = try container.decodeIfPresent(Double.self, forKey: .danmakuOpacity) ?? 0.9
    danmakuMaxLines = try container.decodeIfPresent(Int.self, forKey: .danmakuMaxLines) ?? 0
    danmakuMaxLength = try container.decodeIfPresent(Int.self, forKey: .danmakuMaxLength) ?? 0
    niconicoLowLatency = try container.decodeIfPresent(Bool.self, forKey: .niconicoLowLatency) ?? false
    let legacyGiftVisible = try container.decodeIfPresent(Bool.self, forKey: .niconicoShowGift)
    showGiftEffects = try container.decodeIfPresent(Bool.self, forKey: .showGiftEffects) ?? legacyGiftVisible ?? true
    giftSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .giftSoundEnabled) ?? true
    niconicoShowGift = legacyGiftVisible ?? true
    niconicoShowNicoad = try container.decodeIfPresent(Bool.self, forKey: .niconicoShowNicoad) ?? true
    niconicoShowNotification = try container.decodeIfPresent(Bool.self, forKey: .niconicoShowNotification) ?? true
    autoEconomyOnManyStreams = try container.decodeIfPresent(Bool.self, forKey: .autoEconomyOnManyStreams) ?? true
    platformOrder = try container.decodeIfPresent([StreamPlatform].self, forKey: .platformOrder) ?? StreamPlatform.allCases
  }
}
