import UIKit

// Liquid Glass (iOS 26) adoption with a material-blur fallback. The
// `#if compiler(>=6.2)` guard keeps the iOS 26-only symbols out of older SDKs
// (Xcode < 26) so the project still builds, while `#available` picks the right
// path at runtime.
enum LiquidGlass {
  static func makePanel(
    cornerRadius: CGFloat,
    interactive: Bool = false,
    fallbackStyle: UIBlurEffect.Style = .systemUltraThinMaterialDark
  ) -> UIVisualEffectView {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = interactive
      let view = UIVisualEffectView(effect: glass)
      view.layer.cornerRadius = cornerRadius
      view.clipsToBounds = true
      return view
    }
    #endif
    let view = UIVisualEffectView(effect: UIBlurEffect(style: fallbackStyle))
    view.layer.cornerRadius = cornerRadius
    view.clipsToBounds = true
    return view
  }

  // Builds a capsule button that uses a glass configuration on iOS 26 and a
  // tinted/gray configuration on older systems. `tint` is used as the accent for
  // prominent buttons (e.g. play); pass nil for a neutral button.
  static func makeButton(title: String?, systemImage: String?, tint: UIColor?) -> UIButton {
    let button = UIButton(type: .system)
    var config: UIButton.Configuration
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      config = tint != nil ? .prominentGlass() : .glass()
    } else {
      config = legacyConfiguration(tint: tint)
    }
    #else
    config = legacyConfiguration(tint: tint)
    #endif
    if let title { config.title = title }
    if let systemImage { config.image = UIImage(systemName: systemImage) }
    config.imagePadding = 6
    config.cornerStyle = .capsule
    config.baseForegroundColor = .white
    if let tint { config.baseBackgroundColor = tint }
    config.contentInsets = title == nil
      ? NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
      : NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 16)
    button.configuration = config
    button.tintColor = .white
    return button
  }

  private static func legacyConfiguration(tint: UIColor?) -> UIButton.Configuration {
    if let tint {
      var config = UIButton.Configuration.filled()
      config.baseBackgroundColor = tint.withAlphaComponent(0.85)
      return config
    }
    var config = UIButton.Configuration.gray()
    config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.16)
    return config
  }
}
