import CoreGraphics
import Foundation
import Network

final class NetworkQuality {
  static let shared = NetworkQuality()
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "MultiView.NetworkQuality")
  private var currentPath: NWPath?
  private var lastOnCellular: Bool?
  private var lastChangeAt = Date.distantPast
  private var lastSatisfied: Bool?
  // メインスレッド専用。回線断中は復旧処理が試行回数を消費せず回線復帰を待つ判断に使う。
  private(set) var isReachable = true

  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      self?.queue.async {
        self?.currentPath = path
        self?.detectReachabilityChange(path)
        self?.detectConnectionChange(path)
      }
    }
    monitor.start(queue: queue)
  }

  // 「接続不能→接続可能」への復帰を通知する。回線待ちのプレイヤーはバックオフを待たず
  // その場で再接続できる(以前は同じWi-Fiへの復帰では何も通知されなかった)。
  private func detectReachabilityChange(_ path: NWPath) {
    // .requiresConnection(オンデマンドVPN等)は実際には通信できることがある。確実に
    // 繋がらない .unsatisfied だけを回線断とみなす(誤って回線待ちのまま止めない)。
    let satisfied = path.status != .unsatisfied
    let previous = lastSatisfied
    lastSatisfied = satisfied
    DispatchQueue.main.async {
      self.isReachable = satisfied
      if let previous, previous != satisfied {
        PlaybackDiagnostics.log(satisfied ? "回線: 復帰" : "回線: 切断")
      }
      if previous == false, satisfied {
        NotificationCenter.default.post(name: .multiViewNetworkRestored, object: nil)
      }
    }
  }

  // Tell the app when the connection flips WiFi<->cellular so it can re-pick the
  // quality for already-playing streams (activeQuality is otherwise only read when
  // a player is created). Debounced to real transitions.
  private func detectConnectionChange(_ path: NWPath) {
    guard path.status == .satisfied else { return }
    let onCellular = path.usesInterfaceType(.cellular) || path.isExpensive
    defer { lastOnCellular = onCellular }
    guard let previous = lastOnCellular, previous != onCellular else { return }
    guard Date().timeIntervalSince(lastChangeAt) > 4 else { return }
    lastChangeAt = Date()
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .multiViewNetworkQualityChanged, object: nil)
    }
  }

  func activeQuality(settings: AppSettings) -> PlaybackQuality {
    var path: NWPath?
    queue.sync {
      path = currentPath ?? monitor.currentPath
    }
    if path?.usesInterfaceType(.cellular) == true || path?.isExpensive == true {
      return settings.mobileQuality
    }
    return settings.wifiQuality
  }

  // 自動適応: 同時視聴が3本以上だと帯域不足でカクつくため、ビットレート上限を
  // 自動でエコノミー(約900kbps)へ落とす。2本以下は設定どおりの画質。
  func effectivePeakBitRate(settings: AppSettings) -> Double {
    let base = activeQuality(settings: settings).preferredPeakBitRate
    guard settings.autoEconomyOnManyStreams, AppState.shared.streams.count >= 3 else { return base }
    let economy = PlaybackQuality.economy.preferredPeakBitRate
    return base == 0 ? economy : min(base, economy)
  }

  // エコノミー実効時は解像度上限も 360p(640x360) に制限して通信量を抑える。
  // ビットレート上限(preferredPeakBitRate)だけだと 480p 等が選ばれてデータ消費が大きいため、
  // preferredMaximumResolution で解像度自体を 360p 以下に固定する。high/無制限時は .zero。
  // 「エコノミー実効」条件は effectivePeakBitRate と同じ(回線品質が economy、または自動エコノミー)。
  func effectiveMaximumResolution(settings: AppSettings) -> CGSize {
    let economyActive = activeQuality(settings: settings) == .economy
      || (settings.autoEconomyOnManyStreams && AppState.shared.streams.count >= 3)
    return economyActive ? CGSize(width: 640, height: 360) : .zero
  }
}
