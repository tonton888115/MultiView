import CoreGraphics
import Foundation

// DanmakuEngine.swift(コメントの配置エンジン)の検証。アプリには含めない。
// Mac 上で次のように実行する(GitHub Actions の iOS ビルドでも最初に実行する):
//   cd MultiView/ios
//   swiftc -O MultiView/DanmakuEngine.swift DanmakuEngineChecks/main.swift -o /tmp/danmaku-checks && /tmp/danmaku-checks

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
  checks += 1
  if !condition() {
    failures += 1
    print("FAIL (line \(line)): \(message())")
  }
}

func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.0001) -> Bool {
  abs(a - b) <= tolerance
}

// 毎回同じ並びになる乱数。
struct Generator {
  var state: UInt64

  mutating func next() -> Double {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return Double(state >> 11) / Double(UInt64(1) << 53)
  }
}

func metrics(_ width: CGFloat, _ height: CGFloat, font: Double = 20, speed: Double = 0.13, maxLines: Int = 0) -> DanmakuMetrics {
  DanmakuMetrics(stageSize: CGSize(width: width, height: height), fontSetting: font, speedSetting: speed, maxLines: maxLines)
}

// MARK: 大きさ(公式の表)

let landscape = metrics(640, 360)
check(landscape.isLandscape, "640x360 は横長")
check(near(landscape.lineHeight(.medium), 360 / 11.3), "横長・中の行の高さ = 高さ ÷ 11.3")
check(near(landscape.lineHeight(.big), 360 / 7.8), "横長・大の行の高さ = 高さ ÷ 7.8")
check(near(landscape.lineHeight(.small), 360 / 16.6), "横長・小の行の高さ = 高さ ÷ 16.6")
check(landscape.fontSize(.medium) == 25, "横長・中の文字 = floor(31.86 × 0.8) = 25, 実際 \(landscape.fontSize(.medium))")
check(landscape.fontSize(.big) == 36, "横長・大の文字 = 36, 実際 \(landscape.fontSize(.big))")
check(landscape.fontSize(.small) == 17, "横長・小の文字 = 17, 実際 \(landscape.fontSize(.small))")

let portrait = metrics(360, 640)
check(!portrait.isLandscape, "360x640 は縦長")
check(portrait.fontSize(.medium) == 27, "縦長・中の文字 = floor(640 ÷ 18.8 × 0.8) = 27, 実際 \(portrait.fontSize(.medium))")
check(portrait.fontSize(.big) == 39, "縦長・大の文字 = 39, 実際 \(portrait.fontSize(.big))")
check(portrait.fontSize(.small) == 18, "縦長・小の文字 = 18, 実際 \(portrait.fontSize(.small))")

// 大きさは画面の高さに比例する(タイルでも PiP でも同じ比率)。
let half = metrics(320, 180)
check(near(half.lineHeight(.medium) * 2, landscape.lineHeight(.medium)), "高さが半分なら行の高さも半分")

// 設定の文字サイズは初期値 20 との比率で効く。
check(near(metrics(640, 360, font: 30).lineHeight(.medium), landscape.lineHeight(.medium) * 1.5), "文字サイズ 30 は 1.5 倍")
check(near(metrics(640, 360, font: 100).lineHeight(.medium), landscape.lineHeight(.medium) * 2), "文字サイズの倍率は 2 倍まで")
check(near(metrics(640, 360, font: 1).lineHeight(.medium), landscape.lineHeight(.medium) * 0.6), "文字サイズの倍率は 0.6 倍まで")

// MARK: 舞台と流れ方

check(near(landscape.flowStageWidth, 480), "16:9 の舞台は 4:3 の幅(480)")
check(near(landscape.flowStageRight, 560), "舞台の右端は 560")
check(near(metrics(400, 300).flowStageWidth, 400), "4:3 の画面は舞台 = 画面の幅")
check(near(portrait.flowStageWidth, 360), "縦長 9:16 の舞台 = 画面の幅")
check(landscape.flowDuration == 6 && landscape.flowLead == 1 && landscape.fixedDuration == 3, "表示時間: 流れる 6 秒・前後 1 秒・固定 3 秒")

do {
  var stage = DanmakuStage(metrics: landscape)
  let lineHeight = landscape.lineHeight(.medium)
  let placed = stage.add(position: .flow, size: CGSize(width: 100, height: lineHeight), now: 10)
  let item = placed.item
  check(item.y == 0 && !placed.overflowed, "最初のコメントは一番上の段")
  check(near(item.speed, 145), "速さ = (舞台 480 + 幅 100) ÷ 4 秒 = 145, 実際 \(item.speed)")
  check(near(item.x(at: 10), 705), "流し始めは舞台の右端より 1 秒ぶん右(705)= 画面の右外")
  check(item.x(at: 10) >= 640, "流し始めは画面の右外")
  check(near(item.x(at: 11), 560), "1 秒後に舞台の右端")
  check(near(item.x(at: 15) + 100, 80), "5 秒後に舞台の左端(80)を右端が抜ける")
  check(item.x(at: 16) + 100 < 0, "6 秒後には画面の左外")
  check(item.endTime == 16, "表示は 6 秒")
  // 長いコメントほど速い。
  let long = stage.add(position: .flow, size: CGSize(width: 800, height: lineHeight), now: 10).item
  check(long.speed > item.speed, "長いコメントの方が速い")
  check(near(long.speed, 320), "速さ = (480 + 800) ÷ 4 = 320")
}

do {
  // 設定の速度 200%: 時間が半分になる。
  let fast = metrics(640, 360, speed: 0.26)
  var stage = DanmakuStage(metrics: fast)
  let item = stage.add(position: .flow, size: CGSize(width: 100, height: 30), now: 0).item
  check(fast.flowDuration == 3 && fast.flowLead == 0.5, "速度 200% は表示 3 秒・前後 0.5 秒")
  check(near(item.speed, 290), "速度 200% の速さは 2 倍")
  check(near(item.x(at: 0.5), 560), "0.5 秒後に舞台の右端")
}

// MARK: 段の決め方

do {
  var stage = DanmakuStage(metrics: landscape)
  let lineHeight = landscape.lineHeight(.medium)
  let size = CGSize(width: 200, height: lineHeight)
  let step = lineHeight + DanmakuStage.rowMargin
  let a = stage.add(position: .flow, size: size, now: 0).item
  let b = stage.add(position: .flow, size: size, now: 0).item
  let c = stage.add(position: .flow, size: size, now: 0).item
  check(a.y == 0, "1 件目は一番上")
  check(near(b.y, step), "同時に来た 2 件目は 2 段目")
  check(near(c.y, step * 2), "同時に来た 3 件目は 3 段目")
  // 幅 200 のコメントは 1.18 秒後から同じ段に入れる(舞台に入る時点で前のコメントの後ろにいる)。
  let tooEarly = stage.add(position: .flow, size: size, now: 1.0).item
  check(near(tooEarly.y, step * 3), "1.0 秒後はまだぶつかるので空いている 4 段目、実際 \(tooEarly.y)")
  let clear = stage.add(position: .flow, size: size, now: 1.2).item
  check(clear.y == 0, "1.2 秒後は一番上の段が使える、実際 \(clear.y)")
}

do {
  // 追いつき: 短いコメントの後ろに長い(=速い)コメントが来ると、入り口では離れていても途中で追いつく。
  var stage = DanmakuStage(metrics: landscape)
  let lineHeight = landscape.lineHeight(.medium)
  _ = stage.add(position: .flow, size: CGSize(width: 50, height: lineHeight), now: 0)
  let chaser = stage.add(position: .flow, size: CGSize(width: 1000, height: lineHeight), now: 1.0).item
  check(chaser.y > 0, "追いつくコメントは同じ段に入れない")
  var later = DanmakuStage(metrics: landscape)
  _ = later.add(position: .flow, size: CGSize(width: 50, height: lineHeight), now: 0)
  let safe = later.add(position: .flow, size: CGSize(width: 1000, height: lineHeight), now: 2.8).item
  check(safe.y == 0, "追いつかないだけ離れていれば同じ段、実際 \(safe.y)")
}

do {
  // 固定コメント: 上は上から、下は下から積む。流れるコメントとは別に数える。
  var stage = DanmakuStage(metrics: landscape)
  let lineHeight = landscape.lineHeight(.medium)
  let size = CGSize(width: 300, height: lineHeight)
  let step = lineHeight + DanmakuStage.rowMargin
  let top1 = stage.add(position: .top, size: size, now: 0).item
  let top2 = stage.add(position: .top, size: size, now: 0.5).item
  let bottom1 = stage.add(position: .bottom, size: size, now: 0).item
  let bottom2 = stage.add(position: .bottom, size: size, now: 0.5).item
  let flow = stage.add(position: .flow, size: size, now: 0.5).item
  check(top1.y == 0 && near(top2.y, step), "上固定は上から積む")
  check(near(bottom1.y, 360 - lineHeight) && near(bottom2.y, 360 - lineHeight - step), "下固定は下から積む")
  check(flow.y == 0, "流れるコメントは固定コメントと別に段を決める")
  check(near(top1.x(at: 0), 170) && near(top1.x(at: 2), 170), "固定コメントは左右中央で動かない")
  check(top1.endTime == 3, "固定コメントは 3 秒")
  // 3 秒たてば同じ段が空く。
  let top3 = stage.add(position: .top, size: size, now: 3.2).item
  check(top3.y == 0, "上固定は 3 秒後に一番上が空く、実際 \(top3.y)")
}

do {
  // 空いた段が無い時は捨てずに、領域の中のランダムな高さへ。
  var stage = DanmakuStage(metrics: landscape)
  stage.randomUnit = { 0.5 }
  let lineHeight = landscape.lineHeight(.medium)
  let size = CGSize(width: 600, height: lineHeight)
  var rows: [CGFloat] = []
  for _ in 0..<11 {
    let placed = stage.add(position: .flow, size: size, now: 0)
    check(!placed.overflowed, "11 段目までは収まる")
    rows.append(placed.item.y)
  }
  check(Set(rows.map { Int(($0 * 100).rounded()) }).count == 11, "11 件は全部違う段")
  check(rows.allSatisfy { $0 + lineHeight <= 360 }, "どの段も画面に収まる")
  let extra = stage.add(position: .flow, size: size, now: 0)
  check(extra.overflowed, "12 件目は空きが無い")
  check(near(extra.item.y, (360 - lineHeight) / 2), "空きが無い時は領域の中のランダムな高さ(乱数 0.5 = 中央)")
  check(stage.items.count == 12, "空きが無くても捨てない")
}

do {
  // 設定の最大行数。
  let limited = metrics(640, 360, maxLines: 3)
  let lineHeight = limited.lineHeight(.medium)
  check(near(limited.areaHeight, lineHeight * 3), "最大行数 3 は上から 3 行ぶん")
  var stage = DanmakuStage(metrics: limited)
  stage.randomUnit = { 0.999 }
  let size = CGSize(width: 600, height: lineHeight)
  // 行の隙間(0.1)があるので、3 行ぶんの領域に並ぶのは 2 段。あふれた分も領域の中に置く。
  for _ in 0..<6 {
    let placed = stage.add(position: .flow, size: size, now: 0)
    check(placed.item.y >= 0 && placed.item.y + lineHeight <= limited.areaHeight + 0.0001, "最大行数の領域から出ない、y=\(placed.item.y)")
  }
}

do {
  // 同時に表示するのは 50 件まで。超えたら古いものから消す。
  var stage = DanmakuStage(metrics: landscape)
  var evicted: [Int] = []
  var ids: [Int] = []
  for index in 0..<60 {
    let placed = stage.add(position: .flow, size: CGSize(width: 80, height: 30), now: Double(index) * 0.01)
    ids.append(placed.item.id)
    evicted += placed.evictedIDs
  }
  check(stage.items.count == DanmakuStage.maxDisplayCount, "表示中は 50 件")
  check(evicted == Array(ids.prefix(10)), "消すのは古い 10 件")
  check(stage.items.first?.id == ids[10], "残りの先頭は 11 件目")
}

do {
  // 表示時間が終わったものは外れる。
  var stage = DanmakuStage(metrics: landscape)
  let item = stage.add(position: .flow, size: CGSize(width: 80, height: 30), now: 0).item
  check(stage.removeFinished(now: 5.9).isEmpty && stage.items.count == 1, "6 秒たつまでは表示中")
  check(stage.removeFinished(now: 6.0) == [item.id] && stage.items.isEmpty, "6 秒で外れる")
}

do {
  // 領域の大きさが変わった時の追従(PiP の窓の拡大縮小)。
  var stage = DanmakuStage(metrics: landscape)
  let lineHeight = landscape.lineHeight(.medium)
  _ = stage.add(position: .flow, size: CGSize(width: 200, height: lineHeight), now: 0)
  let before = stage.add(position: .flow, size: CGSize(width: 200, height: lineHeight), now: 0).item
  stage.rescale(to: landscape.resized(to: CGSize(width: 320, height: 180)))
  let after = stage.items[1]
  check(near(after.size.width, 100) && near(after.size.height, lineHeight / 2), "大きさが半分になる")
  check(near(after.y, before.y / 2), "段の位置も半分になる")
  check(near(after.x(at: 2), before.x(at: 2) / 2), "横の位置も半分になる")
  check(near(stage.metrics.lineHeight(.medium), lineHeight / 2), "寸法も新しい大きさになる")
}

// MARK: 流し続けた時にぶつからないこと

do {
  var generator = Generator(state: 20261116)
  for stageSize in [CGSize(width: 640, height: 360), CGSize(width: 180, height: 150), CGSize(width: 360, height: 640)] {
    let current = DanmakuMetrics(stageSize: stageSize, fontSetting: 20, speedSetting: 0.13, maxLines: 0)
    var stage = DanmakuStage(metrics: current)
    stage.randomUnit = { 0.3 }
    let lineHeight = current.lineHeight(.medium)
    var placed: [(item: DanmakuItem, overflowed: Bool)] = []
    var time = 0.0
    // 1 秒に 3 件ほどのコメントを 60 秒流す(幅はばらばら)。
    while time < 60 {
      time += generator.next() * 0.66
      let width = stageSize.width * CGFloat(0.05 + generator.next() * 1.4)
      let result = stage.add(position: .flow, size: CGSize(width: width, height: lineHeight), now: time)
      placed.append((result.item, result.overflowed))
    }
    let lead = current.flowLead
    var collisions = 0
    var overflowed = 0
    for index in placed.indices {
      if placed[index].overflowed {
        overflowed += 1
        continue
      }
      let a = placed[index].item
      for other in placed[..<index] where !other.overflowed {
        let b = other.item
        // 縦に重なる(同じ段の)組だけ見る。
        guard a.y < b.y + b.size.height, b.y < a.y + a.size.height else { continue }
        let from = max(a.startTime, b.startTime) + lead
        let to = min(a.endTime, b.endTime) - lead
        guard from <= to else { continue }
        // 舞台の中にいる間(from〜to)に横に重なる時刻が無いこと。
        for stepIndex in 0...20 {
          let moment = from + (to - from) * Double(stepIndex) / 20
          let ax = a.x(at: moment)
          let bx = b.x(at: moment)
          if ax < bx + b.size.width - 0.0001, bx < ax + a.size.width - 0.0001 {
            collisions += 1
            break
          }
        }
      }
    }
    check(collisions == 0, "\(Int(stageSize.width))x\(Int(stageSize.height)): 同じ段で重なる組が \(collisions) 個")
    check(placed.allSatisfy { $0.item.y >= -0.0001 && $0.item.y + lineHeight <= stageSize.height + 0.0001 }, "\(Int(stageSize.width))x\(Int(stageSize.height)): 全部画面の中")
    print("  \(Int(stageSize.width))x\(Int(stageSize.height)): \(placed.count) 件を流して、同じ段で重なった組 \(collisions)、空きが無くランダムに置いた件 \(overflowed)")
  }
}

print("\(checks) 件の確認、失敗 \(failures) 件")
if failures > 0 {
  exit(1)
}
