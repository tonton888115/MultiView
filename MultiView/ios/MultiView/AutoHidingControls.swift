import UIKit

final class AutoHidingControls: NSObject, UIGestureRecognizerDelegate {
  private weak var host: UIView?
  private let controls: [UIView]
  private var hideWorkItem: DispatchWorkItem?

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
    hideWorkItem?.cancel()
    UIView.animate(withDuration: 0.16) {
      self.controls.forEach { $0.alpha = 1 }
    }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      UIView.animate(withDuration: 0.25) {
        self.controls.forEach { $0.alpha = 0 }
      }
    }
    hideWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
  }
}
