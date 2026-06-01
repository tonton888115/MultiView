import UIKit

// Viewing UI: the grid/stacked ViewingController. Per-cell views live in
// StreamCellView.swift and FocusedStreamView.swift.

final class ViewingController: UIViewController {
  private let scrollView = UIScrollView()
  private let stack = UIStackView()
  private var focused: StreamItem?
  private weak var dragSourceCell: StreamCellView?
  private weak var dragTargetCell: StreamCellView?
  private let reorderIndicator = UIView()
  private var dragSnapshot: UIView?
  private var dragSnapshotCenterOffset = CGPoint.zero
  private var dragSourceStream: StreamItem?
  private var dragInsertIndex: Int?
  private var lastAutoReloadAt = Date.distantPast

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)
    configureScroll()
    configureReorderIndicator()
    reload()
    NotificationCenter.default.addObserver(self, selector: #selector(reloadAndResume), name: .multiViewReloadAndResume, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(networkQualityChanged), name: .multiViewNetworkQualityChanged, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(playbackErrored), name: .multiViewPlaybackErrored, object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func reloadAndResume() {
    reload()
    resumePlaybackAfterReload()
  }

  private func resumePlaybackAfterReload() {
    [0.2, 0.6, 1.2, 2.4].forEach { delay in
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        PlaybackCoordinator.shared.resumeAll()
      }
    }
  }

  @objc private func networkQualityChanged() {
    // Rebuild players at the new network's quality — but only when the two profiles
    // actually differ, otherwise the switch would change nothing.
    let settings = AppState.shared.settings
    guard settings.wifiQuality != settings.mobileQuality else { return }
    reloadAndResume()
  }

  @objc private func playbackErrored() {
    // Debounced auto-refresh to clear a recoverable error. Capped at once per 45s
    // and coalesced so a permanently-failing stream can't trigger a reload loop.
    guard Date().timeIntervalSince(lastAutoReloadAt) > 45 else { return }
    lastAutoReloadAt = Date()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      self?.reloadAndResume()
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    PlaybackCoordinator.shared.resumeAll()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      PlaybackCoordinator.shared.resumeAll()
    }
  }

  func reload() {
    guard isViewLoaded else { return }
    clearStack()
    let streams = AppState.shared.streams
    if streams.isEmpty {
      stack.addArrangedSubview(emptyView())
      return
    }
    addPlaybackBar()
    if let focused, streams.contains(focused) {
      let focusedView = FocusedStreamView(stream: focused, onClose: { [weak self] in
        self?.focused = nil
        self?.reload()
      })
      stack.addArrangedSubview(focusedView)
      // 展開（1配信フル表示）は可視領域いっぱいに広げる（再生バー＋余白分を引いた高さ）。
      focusedView.heightAnchor.constraint(
        equalTo: scrollView.frameLayoutGuide.heightAnchor, constant: -80
      ).isActive = true
      PlaybackCoordinator.shared.resumeAll()
      return
    }
    // Every platform now has a dedicated per-cell native player, so all streams go
    // through addCells (grid / stacked). The old single-WebView fallback is gone.
    addCells(streams)
    PlaybackCoordinator.shared.resumeAll()
  }

  private func clearStack() {
    stack.arrangedSubviews.forEach { view in
      stopPlayback(in: view)
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }

  private func stopPlayback(in view: UIView) {
    (view as? PlaybackStoppable)?.stopPlayback()
    view.subviews.forEach { stopPlayback(in: $0) }
  }

  private func configureScroll() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scrollView)
    scrollView.addSubview(stack)
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 10),
      stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -10),
      stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -18)
    ])
  }

  private func makeCell(_ stream: StreamItem) -> StreamCellView {
    StreamCellView(stream: stream, onFocus: { [weak self] in
      self?.focused = stream
      self?.reload()
    }, onReorder: { [weak self] cell, gesture in
      self?.handleReorder(cell: cell, gesture: gesture)
    })
  }

  private func addStackedCell(_ stream: StreamItem) {
    let cell = makeCell(stream)
    stack.addArrangedSubview(cell)
    cell.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 9 / 16).isActive = true
    cell.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
  }

  private func addCells(_ streams: [StreamItem]) {
    if AppState.shared.settings.layoutMode == .grid {
      addGrid(streams)
      return
    }
    streams.forEach { addStackedCell($0) }
  }

  private func addPlaybackBar() {
    let host = UIView()
    host.translatesAutoresizingMaskIntoConstraints = false

    let row = UIStackView()
    row.axis = .horizontal
    row.spacing = 8
    row.alignment = .center
    row.distribution = .fill
    row.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(row)

    // Clear segmented toggle: the selected side (縦 / グリッド) is highlighted.
    let layoutControl = UISegmentedControl(items: [
      UIImage(systemName: "rectangle.grid.1x2") ?? UIImage(),
      UIImage(systemName: "square.grid.2x2") ?? UIImage()
    ])
    layoutControl.selectedSegmentIndex = AppState.shared.settings.layoutMode == .stacked ? 0 : 1
    layoutControl.selectedSegmentTintColor = .systemBlue
    layoutControl.setImage(UIImage(systemName: "rectangle.grid.1x2"), forSegmentAt: 0)
    layoutControl.setImage(UIImage(systemName: "square.grid.2x2"), forSegmentAt: 1)
    layoutControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
    layoutControl.translatesAutoresizingMaskIntoConstraints = false
    layoutControl.addAction(UIAction { [weak self] actionEvent in
      guard let control = actionEvent.sender as? UISegmentedControl else { return }
      var settings = AppState.shared.settings
      settings.layoutMode = control.selectedSegmentIndex == 0 ? .stacked : .grid
      AppState.shared.settings = settings
      self?.reload()
    }, for: .valueChanged)

    let spacer = UIView()
    spacer.translatesAutoresizingMaskIntoConstraints = false

    let handoffButton = iconButton(systemName: "qrcode", accessibilityLabel: "引き継ぎ") { [weak self] in
      self?.present(UINavigationController(rootViewController: HandoffController()), animated: true)
    }
    let addButton = iconButton(systemName: "plus", accessibilityLabel: "追加") { [weak self] in
      self?.present(AddStreamController(), animated: true)
    }
    let reloadButton = iconButton(systemName: "arrow.triangle.2.circlepath", accessibilityLabel: "更新") { [weak self] in
      self?.reload()
      self?.resumePlaybackAfterReload()
    }
    row.addArrangedSubview(layoutControl)
    row.addArrangedSubview(spacer)
    row.addArrangedSubview(handoffButton)
    row.addArrangedSubview(addButton)
    row.addArrangedSubview(reloadButton)

    stack.addArrangedSubview(host)
    NSLayoutConstraint.activate([
      host.heightAnchor.constraint(equalToConstant: 40),
      row.centerYAnchor.constraint(equalTo: host.centerYAnchor),
      row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      layoutControl.widthAnchor.constraint(equalToConstant: 96),
      layoutControl.heightAnchor.constraint(equalToConstant: 34),
      handoffButton.widthAnchor.constraint(equalToConstant: 40),
      handoffButton.heightAnchor.constraint(equalToConstant: 36),
      addButton.widthAnchor.constraint(equalToConstant: 38),
      addButton.heightAnchor.constraint(equalToConstant: 36),
      reloadButton.widthAnchor.constraint(equalToConstant: 46),
      reloadButton.heightAnchor.constraint(equalToConstant: 36)
    ])
  }

  private func iconButton(systemName: String, accessibilityLabel: String, action: @escaping () -> Void) -> UIButton {
    let button = LiquidGlass.makeButton(title: nil, systemImage: systemName, tint: nil)
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    button.accessibilityLabel = accessibilityLabel
    return button
  }

  private func playbackButton(title: String, icon: String, color: UIColor?, action: @escaping () -> Void) -> UIButton {
    let button = LiquidGlass.makeButton(title: title, systemImage: icon, tint: color)
    button.addAction(UIAction { actionEvent in
      guard let sender = actionEvent.sender as? UIButton else {
        action()
        return
      }
      let originalTitle = sender.configuration?.title
      sender.alpha = 0.62
      sender.configuration?.title = "実行中"
      action()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        sender.alpha = 1
        sender.configuration?.title = originalTitle
      }
    }, for: .touchUpInside)
    return button
  }

  private func addCloseBar(_ streams: [StreamItem]) {
    let scroller = UIScrollView()
    scroller.showsHorizontalScrollIndicator = false
    scroller.translatesAutoresizingMaskIntoConstraints = false
    let row = UIStackView()
    row.axis = .horizontal
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    scroller.addSubview(row)

    streams.forEach { stream in
      let group = UIStackView()
      group.axis = .horizontal
      group.spacing = 2
      group.alignment = .fill
      group.backgroundColor = UIColor.white.withAlphaComponent(0.12)
      group.layer.cornerRadius = 15
      group.clipsToBounds = true

      let open = UIButton(type: .system)
      open.setTitle("\(stream.platform.label) / \(stream.channel)", for: .normal)
      open.setTitleColor(.white, for: .normal)
      open.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
      open.contentEdgeInsets = UIEdgeInsets(top: 7, left: 11, bottom: 7, right: 9)
      open.addAction(UIAction { [weak self] _ in
        self?.focused = stream
        self?.reload()
      }, for: .touchUpInside)

      let close = UIButton(type: .system)
      close.setImage(UIImage(systemName: "xmark"), for: .normal)
      close.tintColor = .white
      close.contentEdgeInsets = UIEdgeInsets(top: 7, left: 8, bottom: 7, right: 11)
      close.addAction(UIAction { _ in AppState.shared.remove(stream) }, for: .touchUpInside)

      group.addArrangedSubview(open)
      group.addArrangedSubview(close)
      row.addArrangedSubview(group)
    }

    stack.addArrangedSubview(scroller)
    NSLayoutConstraint.activate([
      scroller.heightAnchor.constraint(equalToConstant: 38),
      row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
      row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
      row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
      row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor)
    ])
  }

  private func addGrid(_ streams: [StreamItem]) {
    // Pairs go two-up; the trailing stream(s) get their own full-width row so they
    // read as the "main" view and no empty space is left beside a cell.
    //   - odd count : the last 1 stream is full-width (大きい表示 末尾1つ)
    //   - even count: the last 2 streams are full-width, stacked (大きい表示 2つ)
    let bigCount = streams.count % 2 == 0 ? 2 : 1
    let pairedCount = streams.count - bigCount
    var index = 0
    while index + 1 < pairedCount {
      let row = UIStackView()
      row.axis = .horizontal
      row.spacing = 10
      row.distribution = .fillEqually
      row.addArrangedSubview(makeCell(streams[index]))
      row.addArrangedSubview(makeCell(streams[index + 1]))
      stack.addArrangedSubview(row)
      row.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 9 / 32).isActive = true
      row.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
      index += 2
    }
    while index < streams.count {
      addStackedCell(streams[index])
      index += 1
    }
  }

  private func handleReorder(cell: StreamCellView, gesture: UIGestureRecognizer) {
    guard focused == nil, AppState.shared.streams.count > 1 else { return }
    let location = gesture.location(in: view)
    switch gesture.state {
    case .began:
      beginReorder(cell: cell, at: location)
    case .changed:
      updateReorder(at: location)
    case .ended:
      finishReorder(commit: true)
    case .cancelled, .failed:
      finishReorder(commit: false)
    default:
      break
    }
  }

  private func configureReorderIndicator() {
    reorderIndicator.backgroundColor = .systemGreen
    reorderIndicator.layer.cornerRadius = 2
    reorderIndicator.layer.shadowColor = UIColor.black.cgColor
    reorderIndicator.layer.shadowOpacity = 0.24
    reorderIndicator.layer.shadowRadius = 8
    reorderIndicator.layer.shadowOffset = CGSize(width: 0, height: 3)
    reorderIndicator.isHidden = true
    reorderIndicator.alpha = 0
    view.addSubview(reorderIndicator)
  }

  private func beginReorder(cell: StreamCellView, at location: CGPoint) {
    guard dragSnapshot == nil else { return }
    dragSourceCell = cell
    dragTargetCell = cell
    dragSourceStream = cell.stream
    scrollView.isScrollEnabled = false
    cell.setReorderSourceActive(true)
    let snapshot = cell.snapshotView(afterScreenUpdates: false) ?? UIView(frame: cell.bounds)
    let sourceFrame = cell.convert(cell.bounds, to: view)
    snapshot.frame = sourceFrame
    dragSnapshotCenterOffset = CGPoint(x: sourceFrame.midX - location.x, y: sourceFrame.midY - location.y)
    snapshot.layer.shadowColor = UIColor.black.cgColor
    snapshot.layer.shadowOpacity = 0.35
    snapshot.layer.shadowRadius = 14
    snapshot.layer.shadowOffset = CGSize(width: 0, height: 8)
    snapshot.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
    view.addSubview(snapshot)
    view.bringSubviewToFront(reorderIndicator)
    view.bringSubviewToFront(snapshot)
    dragSnapshot = snapshot
    updateReorder(at: location)
  }

  private func updateReorder(at location: CGPoint) {
    dragSnapshot?.center = CGPoint(
      x: location.x + dragSnapshotCenterOffset.x,
      y: location.y + dragSnapshotCenterOffset.y
    )
    guard let target = reorderCell(at: location),
          let targetIndex = AppState.shared.streams.firstIndex(where: { $0.id == target.stream.id }) else {
      dragInsertIndex = nil
      hideReorderIndicator()
      return
    }
    if target !== dragTargetCell {
      dragTargetCell?.setDropTargetActive(false)
      dragTargetCell = target
      if target !== dragSourceCell {
        target.setDropTargetActive(true)
      }
    }
    let frame = target.convert(target.bounds, to: view)
    let insertAfterTarget = location.y > frame.midY
    dragInsertIndex = targetIndex + (insertAfterTarget ? 1 : 0)
    showReorderIndicator(near: frame, after: insertAfterTarget)
  }

  private func finishReorder(commit: Bool) {
    scrollView.isScrollEnabled = true
    let sourceCell = dragSourceCell
    let targetCell = dragTargetCell
    let sourceStream = dragSourceStream
    let insertIndex = dragInsertIndex
    dragSourceCell = nil
    dragTargetCell = nil
    dragSourceStream = nil
    dragInsertIndex = nil
    dragSnapshotCenterOffset = .zero

    sourceCell?.setReorderSourceActive(false)
    targetCell?.setDropTargetActive(false)
    hideReorderIndicator()

    let snapshot = dragSnapshot
    dragSnapshot = nil
    UIView.animate(withDuration: 0.16, animations: {
      if let sourceCell, let snapshot {
        snapshot.frame = sourceCell.convert(sourceCell.bounds, to: self.view)
      }
      snapshot?.alpha = 0
    }, completion: { _ in
      snapshot?.removeFromSuperview()
    })

    guard commit,
          let sourceStream,
          let from = AppState.shared.streams.firstIndex(where: { $0.id == sourceStream.id }),
          let insertIndex,
          insertIndex != from,
          insertIndex != from + 1 else { return }
    moveStream(from: from, to: insertIndex)
  }

  private func moveStream(from sourceIndex: Int, to rawInsertIndex: Int) {
    var next = AppState.shared.streams
    let moved = next.remove(at: sourceIndex)
    let adjustedInsertIndex = sourceIndex < rawInsertIndex ? rawInsertIndex - 1 : rawInsertIndex
    next.insert(moved, at: max(0, min(adjustedInsertIndex, next.count)))
    AppState.shared.streams = next
  }

  private func showReorderIndicator(near targetFrame: CGRect, after: Bool) {
    let y = after ? targetFrame.maxY : targetFrame.minY
    let frame = CGRect(x: targetFrame.minX + 10, y: y - 2, width: max(24, targetFrame.width - 20), height: 4)
    if reorderIndicator.isHidden {
      reorderIndicator.frame = frame
      reorderIndicator.transform = CGAffineTransform(scaleX: 0.86, y: 1)
      reorderIndicator.isHidden = false
      UIView.animate(withDuration: 0.18, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.3, options: [.allowUserInteraction, .beginFromCurrentState]) {
        self.reorderIndicator.alpha = 1
        self.reorderIndicator.transform = .identity
      }
      return
    }
    UIView.animate(withDuration: 0.16, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
      self.reorderIndicator.frame = frame
    }
  }

  private func hideReorderIndicator() {
    guard !reorderIndicator.isHidden else { return }
    UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
      self.reorderIndicator.alpha = 0
    } completion: { _ in
      self.reorderIndicator.isHidden = true
      self.reorderIndicator.transform = .identity
    }
  }

  private func reorderCell(at location: CGPoint) -> StreamCellView? {
    let cells = reorderCells(in: stack)
    if let containing = cells.first(where: { $0.convert($0.bounds, to: view).contains(location) }) {
      return containing
    }
    return cells.min { lhs, rhs in
      let left = lhs.convert(lhs.bounds, to: view).centerDistance(to: location)
      let right = rhs.convert(rhs.bounds, to: view).centerDistance(to: location)
      return left < right
    }
  }

  private func reorderCells(in root: UIView) -> [StreamCellView] {
    var result: [StreamCellView] = []
    for subview in root.subviews {
      if let cell = subview as? StreamCellView {
        result.append(cell)
      } else {
        result.append(contentsOf: reorderCells(in: subview))
      }
    }
    return result
  }

  private func emptyView() -> UIView {
    let label = UILabel()
    label.text = "配信がありません\n＋やランキングから追加してください"
    label.textColor = .secondaryLabel
    label.textAlignment = .center
    label.numberOfLines = 0
    label.heightAnchor.constraint(equalToConstant: 420).isActive = true
    return label
  }
}

private extension CGRect {
  func centerDistance(to point: CGPoint) -> CGFloat {
    hypot(midX - point.x, midY - point.y)
  }
}
