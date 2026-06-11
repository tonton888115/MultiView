import UIKit
import WebKit
import AVFoundation
import Network
import ImageIO
import AuthenticationServices
import Security
import CryptoKit

// Danmaku (scrolling comments) + Niconico gift overlay rendering: tokenization, the
// lane renderer, gift effect styles, sound mixer, effect cache, animated-image decoder.
// Extracted from AppDelegate.swift.

enum NativeDanmakuToken {
  case text(String)
  case image(URL)
}

final class NativeDanmakuRenderer {
  private static let imageCache: NSCache<NSURL, UIImage> = {
    let cache = NSCache<NSURL, UIImage>()
    cache.countLimit = 240
    return cache
  }()

  static func emit(
    tokens: [NativeDanmakuToken],
    filterText: String,
    in root: UIView,
    laneCursor: Int,
    settings: AppSettings,
    highlighted: Bool = false
  ) -> Int {
    let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return laneCursor }
    if settings.danmakuMaxLength > 0, trimmed.count > settings.danmakuMaxLength {
      return laneCursor
    }
    guard root.bounds.height > 0, root.bounds.width > 0 else { return laneCursor }

    let fontSize = scaledFontSize(base: settings.danmakuFontSize, in: root)
    let lineHeight = fontSize + 8
    let maxLines = settings.danmakuMaxLines > 0
      ? settings.danmakuMaxLines
      : max(1, Int(root.bounds.height / lineHeight))
    // Pick a lane whose frontmost comment has already entered far enough that a new one
    // (which starts off the right edge) won't overlap it. Uses the presentation layer
    // because UIView.animate sets `frame` to the END position immediately, so the model
    // frame can't tell us where a comment currently is on screen.
    let lane: Int = {
      let clearThreshold = root.bounds.width - 36
      var laneFront = [Int: CGFloat]()
      for sub in root.subviews {
        let f = sub.layer.presentation()?.frame ?? sub.frame
        let subLane = Int((f.minY - 6) / lineHeight)
        guard subLane >= 0, subLane < maxLines else { continue }
        laneFront[subLane] = max(laneFront[subLane] ?? -.greatestFiniteMagnitude, f.maxX)
      }
      for offset in 0..<maxLines {
        let candidate = (laneCursor + offset) % maxLines
        if (laneFront[candidate] ?? -.greatestFiniteMagnitude) < clearThreshold {
          return candidate
        }
      }
      // Every lane still has a comment near the entry edge. Do not drop chat:
      // choose the lane whose leading comment is furthest left so high-volume
      // streams still show the full flow instead of silently losing messages.
      return (0..<maxLines).min { lhs, rhs in
        (laneFront[lhs] ?? -.greatestFiniteMagnitude) < (laneFront[rhs] ?? -.greatestFiniteMagnitude)
      } ?? (laneCursor % maxLines)
    }()
    let comment = makeCommentView(
      tokens: tokens,
      fontSize: fontSize,
      opacity: settings.danmakuOpacity,
      lineHeight: lineHeight,
      highlighted: highlighted
    )
    guard comment.bounds.width > 0 else { return laneCursor }

    let y = CGFloat(lane) * lineHeight + 6
    let startX = root.bounds.width + 12
    comment.frame.origin = CGPoint(x: startX, y: y)
    root.addSubview(comment)

    let travel = startX + comment.bounds.width + 24
    let pixelsPerSecond = max(35, root.bounds.width * CGFloat(settings.danmakuSpeed))
    let duration = TimeInterval(travel / pixelsPerSecond)
    UIView.animate(withDuration: duration, delay: 0, options: [.curveLinear]) {
      comment.frame.origin.x = -comment.bounds.width - 12
    } completion: { _ in
      comment.removeFromSuperview()
    }
    return laneCursor + 1
  }

  static func textTokens(_ text: String) -> [NativeDanmakuToken] {
    [.text(text)]
  }

  // Scale the configured comment size to the cell so text keeps a consistent
  // proportion: bigger in a single-column (wide) cell, smaller in a packed grid
  // (narrow) cell. Reference width ~= a phone single-column cell.
  static func scaledFontSize(base: Double, in view: UIView) -> CGFloat {
    let referenceWidth: CGFloat = 340
    let width = view.bounds.width
    guard width > 0 else { return CGFloat(base) }
    let scale = min(1.8, max(0.55, width / referenceWidth))
    return (CGFloat(base) * scale).rounded()
  }

  private static func makeCommentView(
    tokens: [NativeDanmakuToken],
    fontSize: CGFloat,
    opacity: Double,
    lineHeight: CGFloat,
    highlighted: Bool
  ) -> UIView {
    let container = UIView()
    let horizontalPadding: CGFloat = highlighted ? 8 : 0
    let verticalInset: CGFloat = highlighted ? 2 : 0
    var x: CGFloat = horizontalPadding
    let imageSide = max(18, fontSize * 1.4)

    // UILabel.layer.shadow* は off-screen render を発生させ、複数セル × 多コメントで
     // GPU 負荷と発熱が増える。視認性に必要な「黒い縁取り」は NSAttributedString の
     // NSShadowAttributeName で実現すれば、フォントレンダラ内部で完結し off-screen
     // pass が起きない。
    let textShadow = NSShadow()
    textShadow.shadowColor = UIColor.black
    textShadow.shadowBlurRadius = 2
    textShadow.shadowOffset = CGSize(width: 1, height: 1)
    for token in tokens {
      switch token {
      case .text(let text):
        guard !text.isEmpty else { continue }
        let label = UILabel()
        label.font = .systemFont(ofSize: fontSize, weight: .bold)
        label.attributedText = NSAttributedString(string: text, attributes: [
          .foregroundColor: UIColor.white.withAlphaComponent(CGFloat(opacity)),
          .shadow: textShadow
        ])
        label.sizeToFit()
        label.frame.origin = CGPoint(x: x, y: verticalInset)
        container.addSubview(label)
        x += label.bounds.width
      case .image(let url):
        let imageView = UIImageView(frame: CGRect(x: x + 3, y: max(verticalInset, (lineHeight - imageSide) / 2), width: imageSide, height: imageSide))
        imageView.contentMode = .scaleAspectFit
        imageView.alpha = CGFloat(opacity)
        // 画像はテキストと違い attributed shadow が使えないので CALayer shadow のまま。
        // Animated emotes must not be rasterized; otherwise some GIF/WebP frames freeze.
        imageView.layer.shadowColor = UIColor.black.cgColor
        imageView.layer.shadowRadius = 2
        imageView.layer.shadowOpacity = 1
        imageView.layer.shadowOffset = CGSize(width: 1, height: 1)
        container.addSubview(imageView)
        loadImage(url, into: imageView)
        x += imageSide + 6
      }
    }

    let width = x + horizontalPadding
    container.frame = CGRect(x: 0, y: 0, width: width, height: lineHeight + verticalInset * 2)
    if highlighted {
      container.layer.borderColor = UIColor.systemYellow.cgColor
      container.layer.borderWidth = 2
      container.layer.cornerRadius = 4
      container.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.12)
    }
    return container
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
  static func show(_ text: String, in root: UIView, tint: UIColor) {
    let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { return }
    DispatchQueue.main.async {
      guard root.bounds.width > 0 else { return }
      let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
      panel.layer.cornerRadius = 10
      panel.clipsToBounds = true
      panel.alpha = 0
      panel.translatesAutoresizingMaskIntoConstraints = false

      let accent = UIView()
      accent.backgroundColor = tint
      accent.translatesAutoresizingMaskIntoConstraints = false
      panel.contentView.addSubview(accent)

      let clip = UIView()
      clip.clipsToBounds = true
      clip.translatesAutoresizingMaskIntoConstraints = false
      panel.contentView.addSubview(clip)

      let label = UILabel()
      label.text = message
      label.textColor = .white
      label.font = .systemFont(ofSize: root.bounds.width < 260 ? 11 : 12, weight: .bold)
      label.numberOfLines = 1
      label.lineBreakMode = .byClipping
      clip.addSubview(label)

      root.addSubview(panel)
      NSLayoutConstraint.activate([
        panel.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
        panel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
        panel.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.88),
        panel.heightAnchor.constraint(equalToConstant: root.bounds.width < 260 ? 30 : 34),
        accent.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor),
        accent.topAnchor.constraint(equalTo: panel.contentView.topAnchor),
        accent.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor),
        accent.widthAnchor.constraint(equalToConstant: 3),
        clip.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 8),
        clip.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -10),
        clip.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 4),
        clip.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -4)
      ])

      root.layoutIfNeeded()
      clip.layoutIfNeeded()
      let labelSize = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: clip.bounds.height))
      let labelWidth = max(labelSize.width, clip.bounds.width)
      label.frame = CGRect(x: 0, y: 0, width: labelWidth, height: clip.bounds.height)
      if labelSize.width > clip.bounds.width {
        label.frame.origin.x = clip.bounds.width
        UIView.animate(
          withDuration: min(7.0, max(3.8, Double(labelSize.width / 34.0))),
          delay: 0.35,
          options: [.curveLinear],
          animations: {
            label.frame.origin.x = -labelSize.width
          }
        )
      }

      UIView.animate(withDuration: 0.18) {
        panel.alpha = 1
      }
      UIView.animate(withDuration: 0.25, delay: 5.2, options: []) {
        panel.alpha = 0
      } completion: { _ in
        panel.removeFromSuperview()
      }
    }
  }

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
