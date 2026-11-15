import UIKit
import WebKit
import AVFoundation
import Network
import ImageIO
import AuthenticationServices
import Security
import CryptoKit

// Danmaku (scrolling comments) + Niconico gift overlay rendering: tokenization, the
// comment views (layout comes from DanmakuEngine.swift), gift effect styles, sound mixer,
// effect cache, animated-image decoder. Extracted from AppDelegate.swift.

enum NativeDanmakuToken {
  case text(String)
  case image(URL)
}

/// コメントの書体(ニコ生のコマンド defont / mincho / gothic)。
enum DanmakuFontFace: Equatable {
  case standard
  case mincho
  case gothic
}

/// コメント 1 件の見た目と出し方。何も指定しなければ「白・中サイズ・右から左へ流れる」。
struct DanmakuStyle {
  var size: DanmakuSize = .medium
  var position: DanmakuPosition = .flow
  /// 文字色。nil は白。
  var color: UIColor?
  var fontFace: DanmakuFontFace = .standard
  /// 半透明(ニコ生のコマンド translucent)。
  var translucent = false
  /// 自分が送ったコメント(黄色の枠で囲む)。
  var highlighted = false
}

/// コメントの見た目の寸法。タイルの弾幕(UIView)と PiP の弾幕(画像に描く)で同じものを使う。
struct DanmakuAppearance {
  let font: UIFont
  /// 1 行の高さ(コメントを積む 1 段の高さ)。
  let lineHeight: CGFloat
  let textColor: UIColor
  let shadow: NSShadow
  /// 影が文字の外へはみ出す量。
  let shadowReach: CGFloat
  /// 絵文字画像の一辺(行の高さに収める)と、その左右の隙間。
  let imageSide: CGFloat
  let imageGap: CGFloat
  /// 絵文字画像の不透明度。
  let imageAlpha: CGFloat
  /// 自分のコメントの枠(枠なしは 0)と、枠の内側の左右の余白・角の丸み。
  let borderWidth: CGFloat
  let horizontalPadding: CGFloat
  let cornerRadius: CGFloat

  /// scale: 画面より広い固定コメントを収めるための縮小率(通常は 1)。
  init(metrics: DanmakuMetrics, style: DanmakuStyle, opacity: Double, scale: CGFloat = 1) {
    let fontSize = max(6, (metrics.fontSize(style.size) * scale).rounded(.down))
    lineHeight = max(fontSize, metrics.lineHeight(style.size) * scale)
    // 設定の文字サイズ 20 の時の 1pt に当たる長さ。影・余白・枠を文字の大きさに比例させる。
    let unit = fontSize / 20
    switch style.fontFace {
    case .standard:
      font = .systemFont(ofSize: fontSize, weight: .bold)
    case .mincho:
      font = UIFont(name: "HiraMinProN-W6", size: fontSize) ?? .systemFont(ofSize: fontSize, weight: .bold)
    case .gothic:
      font = UIFont(name: "HiraginoSans-W6", size: fontSize) ?? .systemFont(ofSize: fontSize, weight: .bold)
    }
    let alpha = CGFloat(min(1, max(0, opacity))) * (style.translucent ? 0.5 : 1)
    let base = style.color ?? .white
    textColor = base.withAlphaComponent(alpha)
    imageAlpha = alpha
    // 影は文字の縁取りの役目。黒い文字は白い影にして読めるようにする。
    var red: CGFloat = 1
    var green: CGFloat = 1
    var blue: CGFloat = 1
    var baseAlpha: CGFloat = 1
    _ = base.getRed(&red, green: &green, blue: &blue, alpha: &baseAlpha)
    let isDark = red * 0.299 + green * 0.587 + blue * 0.114 < 0.2
    let blur = max(1, fontSize * 0.1)
    let offset = max(0.5, fontSize * 0.05)
    let textShadow = NSShadow()
    textShadow.shadowColor = isDark ? UIColor.white : UIColor.black
    textShadow.shadowBlurRadius = blur
    textShadow.shadowOffset = CGSize(width: offset, height: offset)
    shadow = textShadow
    shadowReach = (blur + offset).rounded(.up)
    imageSide = lineHeight
    imageGap = max(1, (3 * unit).rounded())
    if style.highlighted {
      borderWidth = max(1, (2 * unit).rounded())
      horizontalPadding = borderWidth + (6 * unit).rounded()
      cornerRadius = max(2, (4 * unit).rounded())
    } else {
      borderWidth = 0
      horizontalPadding = 0
      cornerRadius = 0
    }
  }

  var textAttributes: [NSAttributedString.Key: Any] {
    [.font: font, .foregroundColor: textColor, .shadow: shadow]
  }
}

// タイル 1 枚(弾幕を出すビュー)ごとの、表示中のコメントの状態。
private final class DanmakuStageState {
  var stage: DanmakuStage
  private var views: [Int: UIView] = [:]

  init(metrics: DanmakuMetrics) {
    stage = DanmakuStage(metrics: metrics)
  }

  func track(_ view: UIView, id: Int) {
    views[id] = view
  }

  // 表示が終わった(または上限を超えた)コメントを外す。
  func discard(id: Int) {
    stage.remove(id: id)
    guard let view = views.removeValue(forKey: id) else { return }
    view.layer.removeAllAnimations()
    view.removeFromSuperview()
  }
}

// タイルの弾幕(動画の上を流れるコメント)。大きさ・速さ・何段目に出すかは DanmakuEngine.swift の
// 共通エンジン(ニコ生公式アプリと同じ規則)で決め、ここは UIView として表示するだけ。
// 公式アプリのアプリ内プレイヤーも、コメント 1 件を 1 つの UIView にして等速のアニメーションで流している。
final class NativeDanmakuRenderer {
  private static let imageCache: NSCache<NSURL, UIImage> = {
    let cache = NSCache<NSURL, UIImage>()
    cache.countLimit = 240
    return cache
  }()
  private static var stageStateKey: UInt8 = 0

  // laneCursor は以前の「行を順番に使う」方式の名残。段は共通エンジンが決めるので、流した件数として
  // 返しているだけ(呼び出し側はそのまま保持してよい)。
  static func emit(
    tokens: [NativeDanmakuToken],
    filterText: String,
    in root: UIView,
    laneCursor: Int,
    settings: AppSettings,
    highlighted: Bool = false,
    style: DanmakuStyle = DanmakuStyle()
  ) -> Int {
    let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return laneCursor }
    if settings.danmakuMaxLength > 0, trimmed.count > settings.danmakuMaxLength {
      return laneCursor
    }
    var style = style
    style.highlighted = style.highlighted || highlighted
    // PiP 中の配信なら PiP の映像にも同じコメントを流す(配置は PiP の窓の大きさで同じ規則で決まる)。
    PictureInPictureCoordinator.shared.mirrorDanmaku(tokens: tokens, from: root, settings: settings, style: style)
    guard root.bounds.height > 0, root.bounds.width > 0 else { return laneCursor }

    let metrics = DanmakuMetrics(
      stageSize: root.bounds.size,
      fontSetting: settings.danmakuFontSize,
      speedSetting: settings.danmakuSpeed,
      maxLines: settings.danmakuMaxLines
    )
    let state = stageState(for: root, metrics: metrics)
    let comment = makeCommentView(tokens: tokens, metrics: metrics, style: style, opacity: settings.danmakuOpacity)
    guard comment.bounds.width > 0 else { return laneCursor }

    let now = CACurrentMediaTime()
    let placement = state.stage.add(position: style.position, size: comment.bounds.size, now: now)
    placement.evictedIDs.forEach { state.discard(id: $0) }
    let item = placement.item
    // 文字がにじまないよう、縦位置は画面のピクセルに合わせる。
    let displayScale = max(1, root.traitCollection.displayScale)
    comment.frame.origin = CGPoint(x: item.x(at: now), y: (item.y * displayScale).rounded() / displayScale)
    root.addSubview(comment)
    state.track(comment, id: item.id)

    let remaining = max(0.05, item.endTime - now)
    if item.position == .flow {
      // 等速で左へ。アプリが裏へ回るなどでアニメーションが打ち切られた時も completion で外れる。
      UIView.animate(withDuration: remaining, delay: 0, options: [.curveLinear]) {
        comment.frame.origin.x = item.x(at: item.endTime)
      } completion: { [weak state] _ in
        state?.discard(id: item.id)
      }
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak state] in
        state?.discard(id: item.id)
      }
    }
    return laneCursor + 1
  }

  static func textTokens(_ text: String) -> [NativeDanmakuToken] {
    [.text(text)]
  }

  private static func stageState(for root: UIView, metrics: DanmakuMetrics) -> DanmakuStageState {
    if let existing = objc_getAssociatedObject(root, &stageStateKey) as? DanmakuStageState {
      if existing.stage.metrics != metrics {
        existing.stage.update(metrics: metrics)
      }
      return existing
    }
    let created = DanmakuStageState(metrics: metrics)
    objc_setAssociatedObject(root, &stageStateKey, created, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return created
  }

  private static func makeCommentView(
    tokens: [NativeDanmakuToken],
    metrics: DanmakuMetrics,
    style: DanmakuStyle,
    opacity: Double
  ) -> UIView {
    let view = buildCommentView(tokens: tokens, appearance: DanmakuAppearance(metrics: metrics, style: style, opacity: opacity))
    let stageWidth = metrics.stageSize.width
    guard style.position != .flow, stageWidth > 0, view.bounds.width > stageWidth else { return view }
    // 上/下に固定するコメントが画面より広い時は、収まる大きさまで縮める(公式と同じ)。
    let scale = stageWidth / view.bounds.width
    return buildCommentView(
      tokens: tokens,
      appearance: DanmakuAppearance(metrics: metrics, style: style, opacity: opacity, scale: scale)
    )
  }

  // コメント 1 件のビュー。大きさは「幅 = 中身の幅、高さ = 1 行の高さ」で、これがそのまま配置の箱になる。
  private static func buildCommentView(tokens: [NativeDanmakuToken], appearance: DanmakuAppearance) -> UIView {
    let container = UIView()
    let lineHeight = appearance.lineHeight
    var x = appearance.horizontalPadding
    // UILabel.layer.shadow* は off-screen render を発生させ、複数セル × 多コメントで GPU 負荷と発熱が
    // 増える。縁取りの影は NSAttributedString の影にすれば文字の描画の中で完結する。
    let attributes = appearance.textAttributes
    for token in tokens {
      switch token {
      case .text(let text):
        guard !text.isEmpty else { continue }
        let label = UILabel()
        label.attributedText = NSAttributedString(string: text, attributes: attributes)
        label.sizeToFit()
        label.frame.origin = CGPoint(x: x, y: ((lineHeight - label.bounds.height) / 2).rounded())
        container.addSubview(label)
        x += label.bounds.width
      case .image(let url):
        let side = appearance.imageSide
        let imageView = UIImageView(frame: CGRect(x: x + appearance.imageGap, y: 0, width: side, height: side))
        imageView.contentMode = .scaleAspectFit
        imageView.alpha = appearance.imageAlpha
        // 画像はテキストと違い attributed shadow が使えないので CALayer shadow のまま。
        // Animated emotes must not be rasterized; otherwise some GIF/WebP frames freeze.
        imageView.layer.shadowColor = UIColor.black.cgColor
        imageView.layer.shadowRadius = appearance.shadow.shadowBlurRadius
        imageView.layer.shadowOpacity = 1
        imageView.layer.shadowOffset = appearance.shadow.shadowOffset
        container.addSubview(imageView)
        loadImage(url, into: imageView)
        x += side + appearance.imageGap * 2
      }
    }
    // 中身が無ければ幅 0 のまま返す(呼び出し側で流さない)。
    guard !container.subviews.isEmpty else { return container }
    container.frame = CGRect(x: 0, y: 0, width: x + appearance.horizontalPadding, height: lineHeight)
    if appearance.borderWidth > 0 {
      container.layer.borderColor = UIColor.systemYellow.cgColor
      container.layer.borderWidth = appearance.borderWidth
      container.layer.cornerRadius = appearance.cornerRadius
      container.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.12)
    }
    return container
  }

  /// PiP 用: 共有キャッシュから絵文字画像を取り、無ければ読み込む(completion はメインスレッド)。
  static func fetchImage(_ url: URL, completion: @escaping (UIImage?) -> Void) {
    let key = url as NSURL
    if let cached = imageCache.object(forKey: key) {
      completion(cached)
      return
    }
    URLSession.shared.dataTask(with: url) { data, _, _ in
      let image = data.flatMap { NativeAnimatedImageDecoder.image(from: $0) }
      if let image {
        imageCache.setObject(image, forKey: key)
      }
      DispatchQueue.main.async {
        completion(image)
      }
    }.resume()
  }

  private static func loadImage(_ url: URL, into imageView: UIImageView) {
    let key = url as NSURL
    if let cached = imageCache.object(forKey: key) {
      imageView.image = cached
      if cached.images?.isEmpty == false {
        imageView.startAnimating()
      }
      return
    }
    URLSession.shared.dataTask(with: url) { data, _, _ in
      guard let data, let image = NativeAnimatedImageDecoder.image(from: data) else { return }
      imageCache.setObject(image, forKey: key)
      DispatchQueue.main.async {
        imageView.image = image
        if image.images?.isEmpty == false {
          imageView.startAnimating()
        }
      }
    }.resume()
  }
}

enum NativeGiftEffectStyle: CaseIterable {
  case gift
  case premiumGift
  case heart
  case star
  case flower
  case food
  case rocket
  case firework
  case nicoad
  case levelUp
  case akashic

  var heroSymbol: String {
    switch self {
    case .gift:
      return "gift.fill"
    case .premiumGift:
      return "crown.fill"
    case .heart:
      return "heart.fill"
    case .star:
      return "star.fill"
    case .flower:
      return "camera.macro"
    case .food:
      return "takeoutbag.and.cup.and.straw.fill"
    case .rocket:
      return "paperplane.fill"
    case .firework:
      return "sparkles"
    case .nicoad:
      return "megaphone.fill"
    case .levelUp:
      return "arrow.up.circle.fill"
    case .akashic:
      return "wand.and.stars"
    }
  }

  var particleSymbols: [String] {
    switch self {
    case .gift:
      return ["gift.fill", "sparkle", "circle.fill"]
    case .premiumGift:
      return ["crown.fill", "sparkles", "star.fill"]
    case .heart:
      return ["heart.fill", "heart.circle.fill", "sparkle"]
    case .star:
      return ["star.fill", "sparkles", "circle.fill"]
    case .flower:
      return ["camera.macro", "leaf.fill", "sparkle"]
    case .food:
      return ["takeoutbag.and.cup.and.straw.fill", "fork.knife.circle.fill", "sparkle"]
    case .rocket:
      return ["paperplane.fill", "flame.fill", "sparkles"]
    case .firework:
      return ["sparkles", "burst.fill", "star.fill"]
    case .nicoad:
      return ["megaphone.fill", "speaker.wave.2.fill", "sparkle"]
    case .levelUp:
      return ["arrow.up.circle.fill", "star.fill", "sparkle"]
    case .akashic:
      return ["wand.and.stars", "sparkles", "circle.fill"]
    }
  }

  var accentColor: UIColor {
    switch self {
    case .gift:
      return UIColor.systemPink
    case .premiumGift:
      return UIColor.systemYellow
    case .heart:
      return UIColor.systemRed
    case .star:
      return UIColor.systemYellow
    case .flower:
      return UIColor.systemGreen
    case .food:
      return UIColor.systemOrange
    case .rocket:
      return UIColor.systemTeal
    case .firework:
      return UIColor.systemPurple
    case .nicoad:
      return UIColor.systemBlue
    case .levelUp:
      return UIColor.systemMint
    case .akashic:
      return UIColor.systemIndigo
    }
  }

  var soundFrequencies: [Double] {
    switch self {
    case .gift:
      return [660, 880, 1320]
    case .premiumGift:
      return [523.25, 783.99, 1046.5, 1567.98]
    case .heart:
      return [587.33, 783.99, 1174.66]
    case .star:
      return [739.99, 987.77, 1479.98]
    case .flower:
      return [523.25, 659.25, 880]
    case .food:
      return [440, 554.37, 659.25]
    case .rocket:
      return [392, 784, 1568]
    case .firework:
      return [659.25, 987.77, 1318.51, 1975.53]
    case .nicoad:
      return [349.23, 523.25, 698.46]
    case .levelUp:
      return [523.25, 659.25, 783.99, 1046.5]
    case .akashic:
      return [440, 739.99, 1108.73, 1479.98]
    }
  }
}

final class NativeGiftSoundMixer: NSObject, AVAudioPlayerDelegate {
  static let shared = NativeGiftSoundMixer()

  private var soundCache: [NativeGiftEffectStyle: Data] = [:]
  private var activePlayers: [AVAudioPlayer] = []

  func prewarm() {
    NativeGiftEffectStyle.allCases.forEach { style in
      _ = soundData(for: style)
    }
  }

  func play(style: NativeGiftEffectStyle, enabled: Bool, volume: Float) {
    guard enabled, volume > 0 else { return }
    let data = soundData(for: style)
    DispatchQueue.main.async {
      do {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.volume = min(0.38, max(0.08, volume * 0.28))
        player.prepareToPlay()
        self.activePlayers.append(player)
        player.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
          self.activePlayers.removeAll { $0 === player || !$0.isPlaying }
        }
      } catch {
        self.activePlayers.removeAll { !$0.isPlaying }
      }
    }
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    activePlayers.removeAll { $0 === player || !$0.isPlaying }
  }

  private func soundData(for style: NativeGiftEffectStyle) -> Data {
    if let cached = soundCache[style] { return cached }
    let data = makeWavData(frequencies: style.soundFrequencies, duration: 0.62)
    soundCache[style] = data
    return data
  }

  private func makeWavData(frequencies: [Double], duration: Double) -> Data {
    let sampleRate = 22_050
    let sampleCount = max(1, Int(Double(sampleRate) * duration))
    let dataByteCount = sampleCount * 2
    var data = Data()
    appendASCII("RIFF", to: &data)
    appendUInt32LE(UInt32(36 + dataByteCount), to: &data)
    appendASCII("WAVE", to: &data)
    appendASCII("fmt ", to: &data)
    appendUInt32LE(16, to: &data)
    appendUInt16LE(1, to: &data)
    appendUInt16LE(1, to: &data)
    appendUInt32LE(UInt32(sampleRate), to: &data)
    appendUInt32LE(UInt32(sampleRate * 2), to: &data)
    appendUInt16LE(2, to: &data)
    appendUInt16LE(16, to: &data)
    appendASCII("data", to: &data)
    appendUInt32LE(UInt32(dataByteCount), to: &data)

    for index in 0..<sampleCount {
      let t = Double(index) / Double(sampleRate)
      let attack = min(1.0, t / 0.025)
      let release = min(1.0, max(0.0, (duration - t) / 0.18))
      let envelope = min(attack, release)
      var value = 0.0
      for (offset, frequency) in frequencies.enumerated() {
        let phase = t - Double(offset) * 0.018
        if phase >= 0 {
          value += sin(2.0 * .pi * frequency * phase) * (offset == 0 ? 0.7 : 0.38)
        }
      }
      let normalized = max(-1.0, min(1.0, value / max(1.0, Double(frequencies.count)) * envelope))
      appendInt16LE(Int16(normalized * 18_000), to: &data)
    }
    return data
  }

  private func appendASCII(_ text: String, to data: inout Data) {
    data.append(contentsOf: text.utf8)
  }

  private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
    data.append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
  }

  private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
    data.append(contentsOf: [
      UInt8(value & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 24) & 0xff)
    ])
  }

  private func appendInt16LE(_ value: Int16, to data: inout Data) {
    appendUInt16LE(UInt16(bitPattern: value), to: &data)
  }
}

final class NiconicoGiftEffectCache {
  static let shared = NiconicoGiftEffectCache()

  private let memoryImages = NSCache<NSURL, UIImage>()
  private let queue = DispatchQueue(label: "app.multiview.niconico-gift-cache")
  private var prewarmed = false
  private var inFlight = Set<URL>()
  private var callbacks: [URL: [(UIImage?) -> Void]] = [:]
  private var itemThumbnailURLs: [String: URL] = [:]
  private let itemThumbnailLock = NSLock()
  private var giftionaryAPIPrewarmed = false
  private var giftionaryAPIRequestInFlight = false
  private var giftionaryAPILastAttempt = Date.distantPast

  func prewarmCommonEffects() {
    queue.async {
      guard !self.prewarmed else { return }
      self.prewarmed = true
      NativeGiftSoundMixer.shared.prewarm()
      _ = try? FileManager.default.createDirectory(at: self.cacheDirectory(), withIntermediateDirectories: true)
    }
  }

  func prewarmAsset(_ url: URL?) {
    loadImage(for: url) { _ in }
  }

  func prewarmGiftItem(itemID: String?) {
    prewarmAsset(thumbnailURL(forItemID: itemID))
  }

  func thumbnailURL(forItemID itemID: String?) -> URL? {
    guard let itemID = sanitizedItemID(itemID) else { return nil }
    itemThumbnailLock.lock()
    let mapped = itemThumbnailURLs[itemID]
    itemThumbnailLock.unlock()
    if let mapped {
      return mapped
    }
    return URL(string: "https://secure-dcdn.cdn.nimg.jp/nicoad/res/nage/thumbnail/\(itemID).png")
  }

  func loadImage(for url: URL?, completion: @escaping (UIImage?) -> Void) {
    guard let url, isAllowedGiftAssetURL(url) else {
      DispatchQueue.main.async {
        completion(nil)
      }
      return
    }
    if let cached = memoryImages.object(forKey: url as NSURL) {
      DispatchQueue.main.async {
        completion(cached)
      }
      return
    }
    queue.async {
      if let image = self.diskImage(for: url) {
        self.memoryImages.setObject(image, forKey: url as NSURL)
        DispatchQueue.main.async {
          completion(image)
        }
        return
      }
      self.callbacks[url, default: []].append(completion)
      if self.inFlight.contains(url) { return }
      self.inFlight.insert(url)
      var request = URLRequest(url: url)
      request.timeoutInterval = 8
      URLSession.shared.dataTask(with: request) { data, response, _ in
        var image: UIImage?
        if let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           let data,
           data.count <= 4_000_000 {
          image = NativeAnimatedImageDecoder.image(from: data)
          if let image {
            self.memoryImages.setObject(image, forKey: url as NSURL)
            try? FileManager.default.createDirectory(at: self.cacheDirectory(), withIntermediateDirectories: true)
            try? data.write(to: self.cacheFileURL(for: url), options: [.atomic])
          }
        }
        self.queue.async {
          let completions = self.callbacks.removeValue(forKey: url) ?? []
          self.inFlight.remove(url)
          DispatchQueue.main.async {
            completions.forEach { $0(image) }
          }
        }
      }.resume()
    }
  }

  func prewarmGiftionaryAPI(headers: [String: String]) {
    queue.async {
      guard !self.giftionaryAPIPrewarmed, !self.giftionaryAPIRequestInFlight else { return }
      guard let cookieHeader = headers["Cookie"], !cookieHeader.isEmpty else { return }
      guard let url = URL(string: "https://api.gift.nicovideo.jp/v1/my/giftionary/items/recent") else { return }
      // 失敗時(prewarmed=false のまま)も、展開ごとに critical path で叩き続けないよう最低120秒空ける。
      guard Date().timeIntervalSince(self.giftionaryAPILastAttempt) > 120 else { return }
      self.giftionaryAPILastAttempt = Date()
      self.giftionaryAPIRequestInFlight = true
      var request = URLRequest(url: url)
      request.timeoutInterval = 8
      headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
      URLSession.shared.dataTask(with: request) { data, response, _ in
        var mappings: [(String, URL)] = []
        if let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           let data,
           let json = try? JSONSerialization.jsonObject(with: data) {
          mappings = self.giftionaryItemMappings(in: json)
        }
        self.queue.async {
          self.giftionaryAPIRequestInFlight = false
          if !mappings.isEmpty {
            self.giftionaryAPIPrewarmed = true
          }
          mappings.forEach { itemID, url in
            self.itemThumbnailLock.lock()
            self.itemThumbnailURLs[itemID] = url
            self.itemThumbnailLock.unlock()
            self.prewarmAsset(url)
          }
        }
      }.resume()
    }
  }

  func cachedImage(for url: URL?) -> UIImage? {
    guard let url else { return nil }
    if let cached = memoryImages.object(forKey: url as NSURL) {
      return cached
    }
    guard isAllowedGiftAssetURL(url) else { return nil }
    guard let image = diskImage(for: url) else { return nil }
    memoryImages.setObject(image, forKey: url as NSURL)
    return image
  }

  private func sanitizedItemID(_ itemID: String?) -> String? {
    guard let itemID = itemID?.trimmingCharacters(in: .whitespacesAndNewlines),
          !itemID.isEmpty,
          itemID.count <= 128 else { return nil }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
    guard itemID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    return itemID
  }

  private func giftionaryItemMappings(in value: Any) -> [(String, URL)] {
    var result: [(String, URL)] = []
    func walk(_ value: Any) {
      if let dict = value as? [String: Any] {
        if let itemID = sanitizedItemID(dict["itemId"] as? String),
           let thumbnail = dict["itemThumbnailUrl"] as? String,
           let url = normalizedGiftAssetURL(thumbnail) {
          result.append((itemID, url))
        }
        dict.values.forEach(walk)
        return
      }
      if let array = value as? [Any] {
        array.forEach(walk)
      }
    }
    walk(value)
    return result
  }

  private func normalizedGiftAssetURL(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let url: URL?
    if trimmed.hasPrefix("/") {
      url = URL(string: "https://gift.nicovideo.jp\(trimmed)")
    } else {
      url = URL(string: trimmed)
    }
    guard let url, isAllowedGiftAssetURL(url) else { return nil }
    return url
  }

  private func diskImage(for url: URL) -> UIImage? {
    let fileURL = cacheFileURL(for: url)
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    return NativeAnimatedImageDecoder.image(from: data)
  }

  private func isAllowedGiftAssetURL(_ url: URL) -> Bool {
    guard url.scheme == "https",
          let host = url.host?.lowercased() else { return false }
    return host.hasSuffix("nicovideo.jp") || host.hasSuffix("nimg.jp") || host.hasSuffix("nico.ms")
  }

  private func cacheDirectory() -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("NiconicoGiftEffects", isDirectory: true)
  }

  private func cacheFileURL(for url: URL) -> URL {
    let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return cacheDirectory().appendingPathComponent(digest).appendingPathExtension("asset")
  }
}

enum NativeAnimatedImageDecoder {
  static func image(from data: Data) -> UIImage? {
    animatedImage(from: data) ?? UIImage(data: data)
  }

  private static func animatedImage(from data: Data) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let count = CGImageSourceGetCount(source)
    guard count > 1 else { return nil }

    var images: [UIImage] = []
    var duration: TimeInterval = 0
    for index in 0..<count {
      guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
      images.append(UIImage(cgImage: cgImage))
      duration += frameDuration(at: index, source: source)
    }
    guard !images.isEmpty else { return nil }
    return UIImage.animatedImage(with: images, duration: max(duration, Double(images.count) * 0.08))
  }

  private static func frameDuration(at index: Int, source: CGImageSource) -> TimeInterval {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
          let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
      return 0.1
    }
    let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
    let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
    let value = unclamped ?? clamped ?? 0.1
    return value < 0.02 ? 0.1 : value
  }
}

final class NativeOnceGate {
  private var didRun = false

  func run(_ body: () -> Void) {
    guard !didRun else { return }
    didRun = true
    body()
  }
}

enum NativeEventOverlay {
  static func showSupport(
    title: String,
    subtitle: String?,
    symbolName: String,
    progress: CGFloat?,
    effectStyle: NativeGiftEffectStyle = .gift,
    assetImage: UIImage? = nil,
    in root: UIView,
    tint: UIColor
  ) {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    DispatchQueue.main.async {
      guard root.bounds.width > 0 else { return }
      let effectTint = effectStyle.accentColor
      let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
      panel.layer.cornerRadius = 13
      panel.layer.borderWidth = 1
      panel.layer.borderColor = effectTint.withAlphaComponent(0.48).cgColor
      panel.clipsToBounds = true
      panel.alpha = 0
      panel.transform = CGAffineTransform(translationX: 0, y: -10).scaledBy(x: 0.96, y: 0.96)
      panel.translatesAutoresizingMaskIntoConstraints = false

      let glow = UIView()
      glow.backgroundColor = effectTint.withAlphaComponent(0.22)
      glow.translatesAutoresizingMaskIntoConstraints = false
      panel.contentView.addSubview(glow)

      let iconHost = UIView()
      iconHost.backgroundColor = effectTint.withAlphaComponent(0.28)
      iconHost.layer.cornerRadius = 18
      iconHost.translatesAutoresizingMaskIntoConstraints = false
      panel.contentView.addSubview(iconHost)

      let icon = UIImageView(image: assetImage ?? UIImage(systemName: symbolName) ?? UIImage(systemName: effectStyle.heroSymbol) ?? UIImage(systemName: "sparkles"))
      icon.tintColor = assetImage == nil ? .white : nil
      icon.contentMode = .scaleAspectFit
      icon.layer.cornerRadius = assetImage == nil ? 0 : 6
      icon.clipsToBounds = assetImage != nil
      icon.translatesAutoresizingMaskIntoConstraints = false
      iconHost.addSubview(icon)

      let titleLabel = UILabel()
      titleLabel.text = title
      titleLabel.textColor = .white
      titleLabel.font = .systemFont(ofSize: root.bounds.width < 260 ? 12 : 14, weight: .heavy)
      titleLabel.numberOfLines = 1
      titleLabel.adjustsFontSizeToFitWidth = true
      titleLabel.minimumScaleFactor = 0.76
      titleLabel.translatesAutoresizingMaskIntoConstraints = false
      panel.contentView.addSubview(titleLabel)

      let subtitleLabel = UILabel()
      subtitleLabel.text = subtitle
      subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.78)
      subtitleLabel.font = .systemFont(ofSize: root.bounds.width < 260 ? 10 : 11, weight: .semibold)
      subtitleLabel.numberOfLines = 1
      subtitleLabel.adjustsFontSizeToFitWidth = true
      subtitleLabel.minimumScaleFactor = 0.74
      subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
      panel.contentView.addSubview(subtitleLabel)

      let barTrack = UIView()
      barTrack.backgroundColor = UIColor.white.withAlphaComponent(0.16)
      barTrack.layer.cornerRadius = 2
      barTrack.clipsToBounds = true
      barTrack.translatesAutoresizingMaskIntoConstraints = false
      panel.contentView.addSubview(barTrack)

      let barFill = UIView()
      barFill.backgroundColor = effectTint
      barFill.layer.cornerRadius = 2
      barFill.translatesAutoresizingMaskIntoConstraints = false
      barTrack.addSubview(barFill)

      root.addSubview(panel)
      let panelHeight: CGFloat = subtitle?.isEmpty == false ? 58 : 48
      let fillWidth = barFill.widthAnchor.constraint(equalToConstant: 0)
      NSLayoutConstraint.activate([
        panel.topAnchor.constraint(equalTo: root.topAnchor, constant: 9),
        panel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
        panel.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.9),
        panel.heightAnchor.constraint(equalToConstant: panelHeight),
        glow.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor),
        glow.topAnchor.constraint(equalTo: panel.contentView.topAnchor),
        glow.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor),
        glow.widthAnchor.constraint(equalToConstant: 6),
        iconHost.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 12),
        iconHost.centerYAnchor.constraint(equalTo: panel.contentView.centerYAnchor),
        iconHost.widthAnchor.constraint(equalToConstant: 36),
        iconHost.heightAnchor.constraint(equalToConstant: 36),
        icon.centerXAnchor.constraint(equalTo: iconHost.centerXAnchor),
        icon.centerYAnchor.constraint(equalTo: iconHost.centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 20),
        icon.heightAnchor.constraint(equalToConstant: 20),
        titleLabel.leadingAnchor.constraint(equalTo: iconHost.trailingAnchor, constant: 10),
        titleLabel.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -12),
        titleLabel.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: subtitle?.isEmpty == false ? 9 : 13),
        subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        barTrack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        barTrack.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        barTrack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -7),
        barTrack.heightAnchor.constraint(equalToConstant: progress == nil ? 0 : 4),
        barFill.leadingAnchor.constraint(equalTo: barTrack.leadingAnchor),
        barFill.topAnchor.constraint(equalTo: barTrack.topAnchor),
        barFill.bottomAnchor.constraint(equalTo: barTrack.bottomAnchor),
        fillWidth
      ])

      root.layoutIfNeeded()
      let clamped = max(0, min(1, progress ?? 0))
      fillWidth.constant = barTrack.bounds.width * clamped
      barFill.layer.removeAllAnimations()

      emitGiftBurst(in: root, from: panel, style: effectStyle, assetImage: assetImage, tint: effectTint)

      UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
        panel.alpha = 1
        panel.transform = .identity
        root.layoutIfNeeded()
      }
      UIView.animate(withDuration: 0.18, delay: 0.24, options: [.autoreverse]) {
        iconHost.transform = CGAffineTransform(scaleX: 1.16, y: 1.16)
      } completion: { _ in
        iconHost.transform = .identity
      }
      UIView.animate(withDuration: 0.25, delay: 4.6, options: []) {
        panel.alpha = 0
        panel.transform = CGAffineTransform(translationX: 0, y: -8)
      } completion: { _ in
        panel.removeFromSuperview()
      }
    }
  }

  private static func emitGiftBurst(
    in root: UIView,
    from panel: UIView,
    style: NativeGiftEffectStyle,
    assetImage: UIImage?,
    tint: UIColor
  ) {
    let center = CGPoint(x: panel.frame.midX, y: panel.frame.maxY + min(58, root.bounds.height * 0.18))

    // 中央から広がる発光リング(派手さアップ・自前演出)。2枚を時差で出して二重リングに。
    for ringDelay in [0.0, 0.12] {
      let ring = UIView(frame: CGRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44))
      ring.backgroundColor = .clear
      ring.layer.borderColor = tint.withAlphaComponent(0.9).cgColor
      ring.layer.borderWidth = 4
      ring.layer.cornerRadius = 22
      ring.alpha = 0.0
      root.insertSubview(ring, at: 0)
      UIView.animate(withDuration: 0.72, delay: ringDelay, options: [.curveEaseOut]) {
        ring.transform = CGAffineTransform(scaleX: 3.4, y: 3.4)
        ring.alpha = 0.0
      }
      UIView.animate(withDuration: 0.16, delay: ringDelay) { ring.alpha = 0.85 }
      UIView.animate(withDuration: 0.5, delay: ringDelay + 0.16) { ring.alpha = 0 } completion: { _ in ring.removeFromSuperview() }
    }

    let hero = UIImageView(image: assetImage ?? UIImage(systemName: style.heroSymbol) ?? UIImage(systemName: "sparkles"))
    hero.tintColor = assetImage == nil ? tint : nil
    hero.contentMode = .scaleAspectFit
    hero.alpha = 0
    hero.frame = CGRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60)
    hero.layer.shadowColor = UIColor.black.cgColor
    hero.layer.shadowOpacity = 0.42
    hero.layer.shadowRadius = 10
    hero.layer.shadowOffset = CGSize(width: 0, height: 4)
    root.addSubview(hero)

    UIView.animateKeyframes(withDuration: 1.25, delay: 0.02, options: [.calculationModeCubic]) {
      UIView.addKeyframe(withRelativeStartTime: 0.0, relativeDuration: 0.18) {
        hero.alpha = 0.96
        hero.transform = CGAffineTransform(scaleX: 1.35, y: 1.35).rotated(by: -0.12)
      }
      UIView.addKeyframe(withRelativeStartTime: 0.18, relativeDuration: 0.28) {
        hero.transform = CGAffineTransform(scaleX: 0.98, y: 0.98).rotated(by: 0.08)
      }
      UIView.addKeyframe(withRelativeStartTime: 0.58, relativeDuration: 0.42) {
        hero.alpha = 0
        hero.transform = CGAffineTransform(translationX: 0, y: -34).scaledBy(x: 0.55, y: 0.55)
      }
    } completion: { _ in
      hero.removeFromSuperview()
    }

    let symbols = style.particleSymbols
    let particleCount = 18
    for index in 0..<particleCount {
      let symbol = symbols[index % symbols.count]
      let particle = UIImageView(image: UIImage(systemName: symbol) ?? UIImage(systemName: "sparkle"))
      particle.tintColor = index % 4 == 0 ? UIColor.white : tint
      particle.contentMode = .scaleAspectFit
      particle.alpha = 0
      let side = CGFloat(10 + (index % 4) * 3)
      particle.frame = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
      root.addSubview(particle)

      let angle = CGFloat(index) / CGFloat(particleCount) * .pi * 2.0 - .pi / 2.0
      let radius = CGFloat(48 + (index % 5) * 14)
      let dx = cos(angle) * radius
      let dy = sin(angle) * radius * 0.72
      UIView.animate(
        withDuration: 0.78 + Double(index % 3) * 0.08,
        delay: 0.04 + Double(index) * 0.018,
        options: [.curveEaseOut]
      ) {
        particle.alpha = 0.92
        particle.transform = CGAffineTransform(translationX: dx, y: dy).rotated(by: angle + 0.7).scaledBy(x: 1.55, y: 1.55)
      } completion: { _ in
        UIView.animate(withDuration: 0.22) {
          particle.alpha = 0
        } completion: { _ in
          particle.removeFromSuperview()
        }
      }
    }
  }
}
