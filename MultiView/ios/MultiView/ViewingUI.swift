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
  // 並び替え・追加・削除でプレイヤーを作り直さず使い回すためのセル再利用プール(stream.id -> cell)。
  private var cellPool: [String: StreamCellView] = [:]
  // 再利用セル/行に付けた高さ制約。reload のたびに貼り直すので、冒頭で必ず外す。
  private var cellLayoutConstraints: [NSLayoutConstraint] = []

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

  // 既定では作り直す(rebuildPlayers:true)。並び替え/追加/削除/レイアウト切替のときだけ false を渡し、
  // 生き残る配信のプレイヤーを破棄せず使い回す(黒画面/コールドスタートを避け、並び替えはアニメ可能)。
  func reload(rebuildPlayers: Bool = true) {
    guard isViewLoaded else { return }
    NSLayoutConstraint.deactivate(cellLayoutConstraints)
    cellLayoutConstraints.removeAll()
    detachArrangedSubviews()
    if rebuildPlayers {
      discardAllPooledCells()
    }

    let streams = AppState.shared.streams
    if streams.isEmpty {
      pruneCellPool(keeping: [])
      stack.addArrangedSubview(emptyView())
      return
    }
    if let focused, streams.contains(focused) {
      // 展開中はグリッドのセルを残しても二重再生・帯域消費になるだけなので破棄する。
      // 展開ビューは自前のプレイヤーを持つ(プール対象外)。
      pruneCellPool(keeping: [])
      addPlaybackBar()
      let focusedView = FocusedStreamView(stream: focused, onClose: { [weak self] in
        self?.focused = nil
        self?.reload(rebuildPlayers: true)
      })
      stack.addArrangedSubview(focusedView)
      // 展開（1配信フル表示）は可視領域いっぱいに広げる（再生バー＋余白分を引いた高さ）。
      focusedView.heightAnchor.constraint(
        equalTo: scrollView.frameLayoutGuide.heightAnchor, constant: -80
      ).isActive = true
      PlaybackCoordinator.shared.resumeAll()
      return
    }
    // 消えた配信のセルだけ停止・破棄し、残る配信はプールのプレイヤーを使い回す。
    pruneCellPool(keeping: streams.map { $0.id })
    addPlaybackBar()
    addCells(streams)
    PlaybackCoordinator.shared.resumeAll()
  }

  // 並び替え・追加・削除を、再利用セルを旧位置→新位置へ補間移動させてアニメ反映する
  // (iOSのホーム画面アイコン並べ替えのように、残るセルがスッと退いて新しい配置に収まる)。
  func reloadForStreamsChange() {
    reload(rebuildPlayers: false)
    view.setNeedsLayout()
    UIView.animate(
      withDuration: 0.32, delay: 0,
      usingSpringWithDamping: 0.85, initialSpringVelocity: 0.2,
      options: [.allowUserInteraction, .beginFromCurrentState]
    ) {
      self.view.layoutIfNeeded()
    }
  }

  // stack の現在の中身を外す。再利用セル(StreamCellView)は cellPool が強参照で保持しているため
  // ここでは解放されず、次の addCells で新しい行へ付け替わる(プレイヤー継続)。展開ビューなど
  // プール外の PlaybackStoppable は確実に停止してから捨てる。
  private func detachArrangedSubviews() {
    for sub in stack.arrangedSubviews {
      stack.removeArrangedSubview(sub)
      if !(sub is StreamCellView) {
        stopNonPooledPlayback(in: sub)
      }
      sub.removeFromSuperview()
    }
  }

  // 再利用プール内のセルは停止しない(継続)。それ以外の PlaybackStoppable(展開ビュー等)だけ停止する。
  private func stopNonPooledPlayback(in view: UIView) {
    for sub in view.subviews {
      if sub is StreamCellView { continue }
      stopNonPooledPlayback(in: sub)
    }
    if !(view is StreamCellView) {
      (view as? PlaybackStoppable)?.stopPlayback()
    }
  }

  private func pruneCellPool(keeping ids: [String]) {
    let keep = Set(ids)
    for (id, cell) in cellPool where !keep.contains(id) {
      cell.stopPlayback()
      cell.removeFromSuperview()
      cellPool.removeValue(forKey: id)
    }
  }

  private func discardAllPooledCells() {
    cellPool.values.forEach { cell in
      cell.stopPlayback()
      cell.removeFromSuperview()
    }
    cellPool.removeAll()
  }

  private func configureScroll() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.delaysContentTouches = false
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
    if let existing = cellPool[stream.id] {
      return existing
    }
    let cell = StreamCellView(stream: stream, onFocus: { [weak self] in
      self?.focused = stream
      self?.reload(rebuildPlayers: true)
    }, onReorder: { [weak self] cell, event in
      self?.handleReorder(cell: cell, event: event)
    })
    cellPool[stream.id] = cell
    return cell
  }

  private func addStackedCell(_ stream: StreamItem) {
    let cell = makeCell(stream)
    stack.addArrangedSubview(cell)
    let ratio = cell.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 9 / 16)
    let floor = cell.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
    cellLayoutConstraints.append(contentsOf: [ratio, floor])
    NSLayoutConstraint.activate([ratio, floor])
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
    layoutControl.addAction(UIAction { actionEvent in
      guard let control = actionEvent.sender as? UISegmentedControl else { return }
      var settings = AppState.shared.settings
      settings.layoutMode = control.selectedSegmentIndex == 0 ? .stacked : .grid
      AppState.shared.settings = settings
      // settings 変更は appStateSettingsDidChange 経由で reload されるため、ここでは呼ばない。
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
      let ratio = row.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 9 / 32)
      let floor = row.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
      cellLayoutConstraints.append(contentsOf: [ratio, floor])
      NSLayoutConstraint.activate([ratio, floor])
      index += 2
    }
    while index < streams.count {
      addStackedCell(streams[index])
      index += 1
    }
  }

  private func handleReorder(cell: StreamCellView, event: StreamReorderEvent) {
    guard focused == nil, AppState.shared.streams.count > 1 else { return }
    // スタック(縦1列)はドラッグ中に他セルがリアルタイムに退くライブ並べ替え。グリッドは行構造が
    // 複雑なので従来のスナップショット＋挿入インジケータ方式を維持する。
    let isStacked = AppState.shared.settings.layoutMode == .stacked
    let location = view.convert(event.windowLocation, from: nil)
    switch event.phase {
    case .began:
      if isStacked { beginLiveReorder(cell: cell, at: location) } else { beginReorder(cell: cell, at: location) }
    case .changed:
      if isStacked { updateLiveReorder(at: location) } else { updateReorder(at: location) }
    case .ended:
      if isStacked { finishLiveReorder(commit: true) } else { finishReorder(commit: true) }
    case .cancelled:
      if isStacked { finishLiveReorder(commit: false) } else { finishReorder(commit: false) }
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

  // MARK: - スタックモードのライブ並べ替え(iOSホーム画面のように他セルがリアルタイムに退く)

  private func beginLiveReorder(cell: StreamCellView, at location: CGPoint) {
    guard dragSnapshot == nil else { return }
    dragSourceCell = cell
    dragSourceStream = cell.stream
    scrollView.isScrollEnabled = false

    let sourceFrame = cell.convert(cell.bounds, to: view)
    let snapshot = cell.snapshotView(afterScreenUpdates: false) ?? UIView(frame: cell.bounds)
    snapshot.frame = sourceFrame
    dragSnapshotCenterOffset = CGPoint(x: sourceFrame.midX - location.x, y: sourceFrame.midY - location.y)
    snapshot.layer.shadowColor = UIColor.black.cgColor
    snapshot.layer.shadowOpacity = 0.35
    snapshot.layer.shadowRadius = 14
    snapshot.layer.shadowOffset = CGSize(width: 0, height: 8)
    snapshot.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
    view.addSubview(snapshot)
    view.bringSubviewToFront(snapshot)
    dragSnapshot = snapshot

    // ソースセルは透明にして「隙間」として残す(場所は保持＝他セルが退くと隙間が空いて見える)。
    // 重要: stack からは外さない。外すと進行中のドラッグ入力(セルのジェスチャ/ハンドル)が
    // 切れてしまう。一度 began した touch は alpha を 0 にしても届き続ける。指の下はスナップショットが代役。
    cell.alpha = 0
  }

  private func updateLiveReorder(at location: CGPoint) {
    guard let cell = dragSourceCell, let snapshot = dragSnapshot else { return }
    snapshot.center = CGPoint(x: location.x + dragSnapshotCenterOffset.x, y: location.y + dragSnapshotCenterOffset.y)

    // ソース以外のセルを基準に指のyが入るべき位置を求め、ソースセル(隙間)をそこへ移して他セルを退かせる。
    let others = stack.arrangedSubviews.compactMap { $0 as? StreamCellView }.filter { $0 !== cell }
    var insertBefore = others.count
    for (index, other) in others.enumerated() {
      let frame = other.convert(other.bounds, to: view)
      if location.y < frame.midY {
        insertBefore = index
        break
      }
    }
    let barOffset = (stack.arrangedSubviews.first is StreamCellView) ? 0 : 1
    let desiredStackIndex = min(insertBefore + barOffset, stack.arrangedSubviews.count - 1)
    guard stack.arrangedSubviews.firstIndex(of: cell) != desiredStackIndex else { return }
    UIView.animate(withDuration: 0.22, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
      self.stack.insertArrangedSubview(cell, at: desiredStackIndex)
      self.stack.layoutIfNeeded()
    }
  }

  private func finishLiveReorder(commit: Bool) {
    scrollView.isScrollEnabled = true
    let snapshot = dragSnapshot
    let cell = dragSourceCell
    let newStreams = (commit && cell != nil) ? streamsFromLiveLayout() : nil
    dragSnapshot = nil
    dragSourceCell = nil
    dragSourceStream = nil
    dragSnapshotCenterOffset = .zero

    cell?.alpha = 1
    UIView.animate(withDuration: 0.16, animations: {
      snapshot?.alpha = 0
    }, completion: { _ in
      snapshot?.removeFromSuperview()
    })

    if let newStreams, newStreams.count == AppState.shared.streams.count, newStreams != AppState.shared.streams {
      // 確定: 並びを保存 → appStateStreamsDidChange 経由で再利用＋整列アニメ(プレイヤー継続)。
      AppState.shared.streams = newStreams
    } else {
      // キャンセル / 変化なし: ドラッグ中に動かした並びを streams 順(元の並び)へ戻す。
      reload(rebuildPlayers: false)
    }
  }

  // ドラッグ中の stack の並び(ソースセルも含む)から、確定後の streams 配列を作る。
  private func streamsFromLiveLayout() -> [StreamItem] {
    stack.arrangedSubviews.compactMap { ($0 as? StreamCellView)?.stream }
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
