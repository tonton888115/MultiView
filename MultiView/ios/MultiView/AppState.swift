import Foundation

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
  // 並び替え・追加・削除。生き残る配信のプレイヤーは再利用してよい(作り直さない)。
  func appStateStreamsDidChange()
  // 画質/弾幕/音声など、既存プレイヤーへ反映するには作り直しが要る設定変更。
  func appStateSettingsDidChange()
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

final class AppState {
  static let shared = AppState()

  weak var delegate: AppStateDelegate?
  var streams = Store.loadStreams() {
    didSet {
      Store.saveStreams(streams)
      delegate?.appStateStreamsDidChange()
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
        || settings.showViewerCount != oldValue.showViewerCount
        || settings.layoutMode != oldValue.layoutMode
        || settings.platformOrder != oldValue.platformOrder
        || settings.autoEconomyOnManyStreams != oldValue.autoEconomyOnManyStreams
      if needsReload {
        delegate?.appStateSettingsDidChange()
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
