import CoreGraphics
import Foundation

// コメント(弾幕)の配置エンジン。タイルの弾幕(NativeDanmakuRenderer)と PiP の弾幕(PictureInPicture.swift)の
// 両方がこれを使うので、どこに出しても同じ大きさ・速さ・段の決め方になる。描画はしない(計算だけ)。
//
// 規則はニコ生公式アプリ(jp.co.dwango.nicocas 6.19.0)のコメント描画(CommeDawara)を解析して合わせた。
//  - 大きさ: 行の高さ = 画面の高さ ÷ 行数。行数は横長の画面で 中 11.3 / 大 7.8 / 小 16.6、
//    縦長の画面で 中 18.8 / 大 13.0 / 小 27.7。文字の大きさ = 行の高さ × 0.8 (切り捨て)。
//  - 流れるコメント: 表示は 6 秒。4:3 の「舞台」の幅＋自分の幅を、前後 1 秒を除いた 4 秒で横切る
//    (長いコメントほど速い)。16:9 の画面では舞台の外側も通るので、画面の右外から入って左外へ抜ける。
//  - 上/下に固定するコメント: 左右中央に 3 秒表示。上固定は上から、下固定は下から積む。
//  - 段の決め方: 表示中の同じ種類のコメントを上から順に見て、縦に重なり、かつ横にもぶつかる
//    (後から来た方が舞台に入る時点か、先に終わる方が舞台を出る時点で重なる)ものがあれば、その下
//    (下固定はその上)へずらす。領域に収まらなくなったらランダムな高さに置く(捨てない)。
//  - 同時に表示するのは 50 件まで。超えたら一番古いものから消す。
// アプリの設定は、文字サイズ 20・速度 0.13 を公式相当(100%)として、その比率で効かせる
// (アプリの速度の初期値は 70%。AppSettings.defaultDanmakuSpeed)。

/// コメントの大きさ(ニコ生のコマンド big / small)。
enum DanmakuSize: Equatable {
  case medium
  case big
  case small
}

/// コメントの出し方(ニコ生のコマンド naka / ue / shita)。
enum DanmakuPosition: Equatable {
  case flow
  case top
  case bottom
}

/// 表示領域の大きさと設定から決まる寸法。
struct DanmakuMetrics: Equatable {
  /// 100% に当たる設定値(ニコ生公式アプリと同じ大きさ・速さ)。
  static let officialFontSetting = 20.0
  static let officialSpeedSetting = 0.13

  /// コメントを出す領域の大きさ(タイルは pt、PiP は出力フレームの px)。
  let stageSize: CGSize
  /// 設定の文字サイズ ÷ 公式相当の値。
  let fontScale: CGFloat
  /// 設定の速度 ÷ 公式相当の値。
  let speedScale: Double
  /// 設定の最大行数(0 = 制限なし)。
  let maxLines: Int

  init(stageSize: CGSize, fontSetting: Double, speedSetting: Double, maxLines: Int) {
    self.init(
      stageSize: stageSize,
      fontScale: CGFloat(min(2.0, max(0.6, fontSetting / Self.officialFontSetting))),
      speedScale: min(3.0, max(0.2, speedSetting / Self.officialSpeedSetting)),
      maxLines: max(0, maxLines)
    )
  }

  private init(stageSize: CGSize, fontScale: CGFloat, speedScale: Double, maxLines: Int) {
    self.stageSize = stageSize
    self.fontScale = fontScale
    self.speedScale = speedScale
    self.maxLines = maxLines
  }

  /// 設定はそのままで、領域の大きさだけ変えたもの。
  func resized(to stageSize: CGSize) -> DanmakuMetrics {
    DanmakuMetrics(stageSize: stageSize, fontScale: fontScale, speedScale: speedScale, maxLines: maxLines)
  }

  var isLandscape: Bool {
    stageSize.width >= stageSize.height
  }

  /// 画面の高さに入る行数(設定の文字サイズが公式相当の時)。
  static func linesPerHeight(landscape: Bool, size: DanmakuSize) -> CGFloat {
    switch size {
    case .medium:
      return landscape ? 11.3 : 18.8
    case .big:
      return landscape ? 7.8 : 13.0
    case .small:
      return landscape ? 16.6 : 27.7
    }
  }

  /// 1 行の高さ。コメントを積む時の 1 段の高さでもある。
  func lineHeight(_ size: DanmakuSize) -> CGFloat {
    stageSize.height / Self.linesPerHeight(landscape: isLandscape, size: size) * fontScale
  }

  /// 文字の大きさ。
  func fontSize(_ size: DanmakuSize) -> CGFloat {
    max(6, (lineHeight(size) * 0.8).rounded(.down))
  }

  /// コメントを置ける領域の上端。
  var areaTop: CGFloat {
    0
  }

  /// コメントを置ける領域の高さ(設定の最大行数があれば、上からその行数ぶん)。
  var areaHeight: CGFloat {
    guard maxLines > 0 else { return stageSize.height }
    return min(stageSize.height, CGFloat(maxLines) * lineHeight(.medium))
  }

  /// 流れる速さを決める「舞台」の幅(横長の画面は 4:3、縦長の画面は 9:16 の幅まで)。
  var flowStageWidth: CGFloat {
    min(stageSize.width, isLandscape ? stageSize.height * 4 / 3 : stageSize.height * 9 / 16)
  }

  /// 舞台の右端の x(舞台は画面の左右中央にある)。
  var flowStageRight: CGFloat {
    flowStageWidth + (stageSize.width - flowStageWidth) / 2
  }

  /// 流れるコメントの表示時間(公式は 6 秒)。
  var flowDuration: Double {
    6 / speedScale
  }

  /// 舞台に入るまで・舞台を出てからの時間(公式は 1 秒ずつ)。
  var flowLead: Double {
    1 / speedScale
  }

  /// 固定コメントの表示時間(公式は 3 秒)。
  var fixedDuration: Double {
    3
  }
}

/// 表示中のコメント 1 件(配置済み)。
struct DanmakuItem: Equatable {
  let id: Int
  let position: DanmakuPosition
  /// 配置に使う大きさ(幅 = 文字の幅、高さ = 1 行の高さ。絵文字を大きくしたコメントはその高さ)。
  let size: CGSize
  let startTime: Double
  let endTime: Double
  /// 上端の y。
  var y: CGFloat
  /// startTime での左端の x。
  let startX: CGFloat
  /// 1 秒に左へ進む量(固定コメントは 0)。
  let speed: CGFloat

  /// 時刻 time での左端の x。
  func x(at time: Double) -> CGFloat {
    startX - speed * CGFloat(time - startTime)
  }

  fileprivate func scaled(x factorX: CGFloat, y factorY: CGFloat) -> DanmakuItem {
    DanmakuItem(
      id: id,
      position: position,
      size: CGSize(width: size.width * factorX, height: size.height * factorY),
      startTime: startTime,
      endTime: endTime,
      y: y * factorY,
      startX: startX * factorX,
      speed: speed * factorX
    )
  }
}

/// コメントを 1 件置いた結果。
struct DanmakuPlacement {
  let item: DanmakuItem
  /// 上限(50 件)を超えたため消すコメント。
  let evictedIDs: [Int]
  /// 空いた段が無く、ランダムな高さに置いた。
  let overflowed: Bool
}

/// 1 つの表示領域(タイル 1 枚、または PiP の窓)に出ているコメントの状態。
struct DanmakuStage {
  /// 同時に表示する上限(公式と同じ)。
  static let maxDisplayCount = 50
  /// 段と段の間に空ける隙間(公式と同じ)。
  static let rowMargin: CGFloat = 0.1

  private(set) var metrics: DanmakuMetrics
  /// 表示中のコメント(古い順)。
  private(set) var items: [DanmakuItem] = []
  private var nextID = 1
  /// 0 以上 1 未満の乱数。空きが無い時の高さ決めに使う(検証では決まった値に差し替える)。
  var randomUnit: () -> CGFloat = { CGFloat.random(in: 0..<1) }

  init(metrics: DanmakuMetrics) {
    self.metrics = metrics
  }

  /// 領域の大きさや設定が変わった。表示中のコメントはそのまま(タイル: 動いているビューは作り直さない)。
  mutating func update(metrics: DanmakuMetrics) {
    self.metrics = metrics
  }

  /// 領域の大きさが変わったので、表示中のコメントも同じ比率で合わせる(PiP: 毎フレーム描き直すので追従できる)。
  mutating func rescale(to metrics: DanmakuMetrics) {
    let old = self.metrics.stageSize
    self.metrics = metrics
    let new = metrics.stageSize
    guard old.width > 0, old.height > 0, old != new else { return }
    let factorX = new.width / old.width
    let factorY = new.height / old.height
    items = items.map { $0.scaled(x: factorX, y: factorY) }
  }

  /// 表示時間が終わったコメントを外す。外した id を返す。
  @discardableResult
  mutating func removeFinished(now: Double) -> [Int] {
    var removed: [Int] = []
    items.removeAll { item in
      guard item.endTime <= now else { return false }
      removed.append(item.id)
      return true
    }
    return removed
  }

  mutating func remove(id: Int) {
    items.removeAll { $0.id == id }
  }

  /// コメントを 1 件出す。size は配置に使う大きさ(幅 = 文字の幅、高さ = 1 行の高さ。絵文字を大きくしたコメントはその高さ)。
  mutating func add(position: DanmakuPosition, size: CGSize, now: Double) -> DanmakuPlacement {
    removeFinished(now: now)
    let duration = position == .flow ? metrics.flowDuration : metrics.fixedDuration
    let startX: CGFloat
    let speed: CGFloat
    if position == .flow {
      let lead = metrics.flowLead
      // 舞台の幅＋自分の幅を、前後の lead を除いた時間で横切る。
      let crossing = max(lead, duration - 2 * lead)
      speed = (metrics.flowStageWidth + size.width) / CGFloat(crossing)
      // 舞台の右端に着くのは lead 秒後。それまでは舞台の右外(16:9 の画面なら画面の右外)から近づく。
      startX = metrics.flowStageRight + speed * CGFloat(lead)
    } else {
      speed = 0
      startX = (metrics.stageSize.width - size.width) / 2
    }
    var item = DanmakuItem(
      id: nextID,
      position: position,
      size: size,
      startTime: now,
      endTime: now + duration,
      y: 0,
      startX: startX,
      speed: speed
    )
    nextID += 1
    let row = rowPosition(for: item, now: now)
    item.y = row.y
    items.append(item)
    var evicted: [Int] = []
    while items.count > Self.maxDisplayCount {
      evicted.append(items.removeFirst().id)
    }
    return DanmakuPlacement(item: item, evictedIDs: evicted, overflowed: row.overflowed)
  }

  // 何段目(y)に出すかを決める。
  private func rowPosition(for new: DanmakuItem, now: Double) -> (y: CGFloat, overflowed: Bool) {
    let top = metrics.areaTop
    let areaHeight = metrics.areaHeight
    let height = new.size.height
    // 比べる相手は、表示中の同じ種類のコメントだけ(流れるコメント同士、上固定同士、下固定同士)。
    let others = items.filter { $0.position == new.position && $0.endTime > now }
    switch new.position {
    case .flow, .top:
      guard areaHeight >= height else {
        // 領域より背が高い。流れるコメントは上下中央、上固定は上端に置く。
        return (new.position == .flow ? top + (areaHeight - height) / 2 : top, false)
      }
      var y = top
      // 下端が上にあるものから順に見ていく。
      for other in others.sorted(by: { $0.y + $0.size.height < $1.y + $1.size.height }) {
        guard Self.overlaps(y, height, other.y, other.size.height) else { continue }
        if new.position == .flow, !collides(new, other) { continue }
        y = other.y + other.size.height + Self.rowMargin
        if y < top || top + areaHeight < y + height {
          return (randomRow(height: height), true)
        }
      }
      return (y, false)
    case .bottom:
      var y = top + areaHeight - height
      guard areaHeight >= height else { return (y, false) }
      // 下端が下にあるものから順に見ていく。
      for other in others.sorted(by: { $0.y + $0.size.height > $1.y + $1.size.height }) {
        guard Self.overlaps(y, height, other.y, other.size.height) else { continue }
        y = other.y - height - Self.rowMargin
        if y < top || top + areaHeight < y + height {
          return (randomRow(height: height), true)
        }
      }
      return (y, false)
    }
  }

  // 流れるコメント同士が横にぶつかるか。後から来た方が舞台に入る時点と、先に終わる方が舞台を出る
  // 時点の 2 回だけ調べる(どちらも等速なので、その間は調べなくてよい)。
  private func collides(_ a: DanmakuItem, _ b: DanmakuItem) -> Bool {
    let lead = metrics.flowLead
    let entering = max(a.startTime, b.startTime) + lead
    if Self.overlaps(a.x(at: entering), a.size.width, b.x(at: entering), b.size.width) {
      return true
    }
    let leaving = min(a.endTime, b.endTime) - lead
    return Self.overlaps(a.x(at: leaving), a.size.width, b.x(at: leaving), b.size.width)
  }

  // 空いた段が無い時の置き場所: 領域の中のランダムな高さ。
  private func randomRow(height: CGFloat) -> CGFloat {
    let room = metrics.areaHeight - height
    guard room > 0 else { return metrics.areaTop }
    return metrics.areaTop + randomUnit() * room
  }

  // 区間 [start1, start1+length1) と [start2, start2+length2) が重なるか(端が接するだけなら重ならない)。
  private static func overlaps(_ start1: CGFloat, _ length1: CGFloat, _ start2: CGFloat, _ length2: CGFloat) -> Bool {
    start1 < start2 + length2 && start2 < start1 + length1
  }
}
