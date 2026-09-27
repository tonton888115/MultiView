import UIKit

final class AutoHidingControls: NSObject, UIGestureRecognizerDelegate {
  private weak var host: UIView?
  private let controls: [UIView]
  private var hideWorkItem: DispatchWorkItem?
  // コントロール群の表示/非表示に合わせて呼ばれる(表示=true)。表示中だけ動けばよい
  // 付随処理(同接数の定期取得など)を止めるために使う。
  var onVisibilityChange: ((Bool) -> Void)?
  // ビューモード中はタップしても出さない(常に隠す)。解除後は次のタップから通常どおり。
  var isSuppressed = false {
    didSet {
      guard isSuppressed != oldValue, isSuppressed else { return }
      hideWorkItem?.cancel()
      hideWorkItem = nil
      controls.forEach { $0.alpha = 0 }
      onVisibilityChange?(false)
    }
  }

  init(host: UIView, controls: [UIView]) {
    self.host = host
    self.controls = controls
    super.init()
    let tap = UITapGestureRecognizer(target: self, action: #selector(showTemporarily))
    tap.delegate = self
    tap.cancelsTouchesInView = false
    tap.delaysTouchesBegan = false
    tap.delaysTouchesEnded = false
    host.addGestureRecognizer(tap)
    showTemporarily()
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    true
  }

  @objc func showTemporarily() {
    guard !isSuppressed else { return }
    hideWorkItem?.cancel()
    UIView.animate(withDuration: 0.16) {
      self.controls.forEach { $0.alpha = 1 }
    }
    onVisibilityChange?(true)
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      UIView.animate(withDuration: 0.25) {
        self.controls.forEach { $0.alpha = 0 }
      }
      self.onVisibilityChange?(false)
    }
    hideWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
  }
}
