import UIKit

// Viewing UI: the grid/stacked ViewingController. Per-cell views live in
// StreamCellView.swift and FocusedStreamView.swift.

final class ViewingController: UIViewController {
  private let scrollView = UIScrollView()
  private let stack = UIStackView()
  private let bottomControlsHost = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private let bottomControlsRow = UIStackView()
  private lazy var layoutControl: UISegmentedControl = {
    let control = UISegmentedControl(items: [
      UIImage(systemName: "rectangle.grid.1x2") ?? UIImage(),
      UIImage(systemName: "square.grid.2x2") ?? UIImage()
    ])
    control.selectedSegmentTintColor = .systemBlue
    control.setImage(UIImage(systemName: "rectangle.grid.1x2"), forSegmentAt: 0)
    control.setImage(UIImage(systemName: "square.grid.2x2"), forSegmentAt: 1)
    control.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
    control.translatesAutoresizingMaskIntoConstraints = false
    control.addAction(UIAction { actionEvent in
      guard let control = actionEvent.sender as? UISegmentedControl else { return }
      var settings = AppState.shared.settings
      settings.layoutMode = control.selectedSegmentIndex == 0 ? .stacked : .grid
      AppState.shared.settings = settings
    }, for: .valueChanged)
    return control
  }()
  private var focused: StreamItem?
  private weak var dragSourceCell: StreamCellView?
  private var dragSnapshot: UIView?
  private var dragSnapshotCenterOffset = CGPoint.zero
  private var dragSourceStream: StreamItem?
  private var gridDragSlotFrames: [CGRect] = []
  private var gridDragOriginalFrames: [String: CGRect] = [:]
  private var gridDragCurrentStreams: [StreamItem] = []
  private var lastAutoReloadAt = Date.distantPast
  private var pendingAutoReloadWorkItem: DispatchWorkItem?
  // 並び替え・追加・削除でプレイヤーを作り直さず使い回すためのセル再利用プール(stream.id -> cell)。
  private var cellPool: [String: StreamCellView] = [:]
  // 再利用セル/行に付けた高さ制約。reload のたびに貼り直すので、冒頭で必ず外す。
  private var cellLayoutConstraints: [NSLayoutConstraint] = []

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)
    configureScroll()
    reload()
    NotificationCenter.default.addObserver(self, selector: #selector(reloadAndResume), name: .multiViewReloadAndResume, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(networkQualityChanged), name: .multiViewNetworkQualityChanged, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(playbackErrored), name: .multiViewPlaybackErrored, object: nil)
  }

  deinit {
    pendingAutoReloadWorkItem?.cancel()
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
    // Coalesce failures, but never drop one inside the 45-second debounce window.
    // The old guard returned without scheduling anything, leaving a Niconico cell
    // permanently stopped when its final retry happened during the cooldown.
    guard pendingAutoReloadWorkItem == nil else { return }
    let remainingCooldown = max(0, 45 - Date().timeIntervalSince(lastAutoReloadAt))
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.pendingAutoReloadWorkItem = nil
      self.lastAutoReloadAt = Date()
      self.reloadAndResume()
    }
    pendingAutoReloadWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + remainingCooldown + 2, execute: work)
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
    updateBottomControls()
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
      let focusedView = FocusedStreamView(stream: focused, onClose: { [weak self] in
        self?.focused = nil
        self?.reload(rebuildPlayers: true)
      })
      stack.addArrangedSubview(focusedView)
      // 展開（1配信フル表示）は操作バーを除いたスクロール領域いっぱいに広げる。
      focusedView.heightAnchor.constraint(
        equalTo: scrollView.frameLayoutGuide.heightAnchor, constant: -18
      ).isActive = true
      PlaybackCoordinator.shared.resumeAll()
      return
    }
    // 消えた配信のセルだけ停止・破棄し、残る配信はプールのプレイヤーを使い回す。
    pruneCellPool(keeping: streams.map { $0.id })
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
    view.addSubview(bottomControlsHost)
    scrollView.addSubview(stack)
    configureBottomControls()
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomControlsHost.topAnchor),
      bottomControlsHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bottomControlsHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomControlsHost.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      bottomControlsHost.heightAnchor.constraint(equalToConstant: 56),
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

  private func configureBottomControls() {
    bottomControlsHost.translatesAutoresizingMaskIntoConstraints = false
    bottomControlsHost.backgroundColor = UIColor.black.withAlphaComponent(0.28)
    bottomControlsHost.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
    bottomControlsHost.layer.borderWidth = 0.5

    bottomControlsRow.axis = .horizontal
    bottomControlsRow.spacing = 8
    bottomControlsRow.alignment = .center
    bottomControlsRow.distribution = .fill
    bottomControlsRow.translatesAutoresizingMaskIntoConstraints = false
    bottomControlsHost.contentView.addSubview(bottomControlsRow)

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
    bottomControlsRow.addArrangedSubview(layoutControl)
    bottomControlsRow.addArrangedSubview(spacer)
    bottomControlsRow.addArrangedSubview(handoffButton)
    bottomControlsRow.addArrangedSubview(addButton)
    bottomControlsRow.addArrangedSubview(reloadButton)

    NSLayoutConstraint.activate([
      bottomControlsRow.topAnchor.constraint(equalTo: bottomControlsHost.contentView.topAnchor, constant: 8),
      bottomControlsRow.leadingAnchor.constraint(equalTo: bottomControlsHost.contentView.leadingAnchor, constant: 10),
      bottomControlsRow.trailingAnchor.constraint(equalTo: bottomControlsHost.contentView.trailingAnchor, constant: -10),
      bottomControlsRow.bottomAnchor.constraint(equalTo: bottomControlsHost.contentView.bottomAnchor, constant: -8),
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

  private func updateBottomControls() {
    layoutControl.selectedSegmentIndex = AppState.shared.settings.layoutMode == .stacked ? 0 : 1
  }

  private func iconButton(systemName: String, accessibilityLabel: String, action: @escaping () -> Void) -> UIButton {
    let button = LiquidGlass.makeButton(title: nil, systemImage: systemName, tint: nil)
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    button.accessibilityLabel = accessibilityLabel
    return button
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
    let isStacked = AppState.shared.settings.layoutMode == .stacked
    let location = view.convert(event.windowLocation, from: nil)
    switch event.phase {
    case .began:
      if isStacked { beginLiveReorder(cell: cell, at: location) } else { beginGridLiveReorder(cell: cell, at: location) }
    case .changed:
      if isStacked { updateLiveReorder(at: location) } else { updateGridLiveReorder(at: location) }
    case .ended:
      if isStacked { finishLiveReorder(commit: true) } else { finishGridLiveReorder(commit: true) }
    case .cancelled:
      if isStacked { finishLiveReorder(commit: false) } else { finishGridLiveReorder(commit: false) }
    }
  }

  // MARK: - 並び替えドラッグ共通処理

  private func beginDragSnapshot(for cell: StreamCellView, at location: CGPoint) {
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

    // ソースセルは階層に残して touch を維持し、見た目だけスナップショットへ移す。
    cell.alpha = 0
  }

  @discardableResult
  private func updateDragSnapshot(at location: CGPoint) -> Bool {
    guard let snapshot = dragSnapshot else { return false }
    snapshot.center = CGPoint(x: location.x + dragSnapshotCenterOffset.x, y: location.y + dragSnapshotCenterOffset.y)
    return true
  }

  private func clearDragState() -> UIView? {
    scrollView.isScrollEnabled = true
    let snapshot = dragSnapshot
    dragSnapshot = nil
    dragSourceCell = nil
    dragSourceStream = nil
    dragSnapshotCenterOffset = .zero
    return snapshot
  }

  private func fadeOutDragSnapshot(_ snapshot: UIView?, finalFrame: CGRect? = nil) {
    UIView.animate(withDuration: 0.16, animations: {
      if let finalFrame {
        snapshot?.frame = finalFrame
      }
      snapshot?.alpha = 0
    }, completion: { _ in
      snapshot?.removeFromSuperview()
    })
  }

  // MARK: - グリッドモードのライブ並べ替え

  private func beginGridLiveReorder(cell: StreamCellView, at location: CGPoint) {
    guard dragSnapshot == nil else { return }
    let streams = AppState.shared.streams
    guard streams.contains(where: { $0.id == cell.stream.id }) else { return }

    view.layoutIfNeeded()
    let slotFrames = currentGridSlotFrames(for: streams)
    guard slotFrames.count == streams.count else { return }

    gridDragSlotFrames = slotFrames
    gridDragOriginalFrames = Dictionary(uniqueKeysWithValues: zip(streams.map { $0.id }, slotFrames))
    gridDragCurrentStreams = streams
    beginDragSnapshot(for: cell, at: location)
    updateGridLiveReorder(at: location)
  }

  private func updateGridLiveReorder(at location: CGPoint) {
    guard let sourceStream = dragSourceStream, updateDragSnapshot(at: location) else { return }

    let insertIndex = gridLiveInsertIndex(at: location)
    let orderedStreams = streams(moving: sourceStream, to: insertIndex)
    guard orderedStreams != gridDragCurrentStreams else { return }
    gridDragCurrentStreams = orderedStreams

    UIView.animate(
      withDuration: 0.22, delay: 0,
      usingSpringWithDamping: 0.86, initialSpringVelocity: 0.25,
      options: [.allowUserInteraction, .beginFromCurrentState]
    ) {
      self.applyGridLiveTransforms(for: orderedStreams)
    }
  }

  private func finishGridLiveReorder(commit: Bool) {
    let sourceCell = dragSourceCell
    let sourceStream = dragSourceStream
    let newStreams = (commit && !gridDragCurrentStreams.isEmpty) ? gridDragCurrentStreams : nil
    let finalSnapshotFrame = gridFinalSnapshotFrame(for: sourceStream, in: newStreams) ??
      sourceCell.map { $0.convert($0.bounds, to: view) }

    let snapshot = clearDragState()
    gridDragSlotFrames.removeAll()
    gridDragOriginalFrames.removeAll()
    gridDragCurrentStreams.removeAll()

    if let newStreams, newStreams.count == AppState.shared.streams.count, newStreams != AppState.shared.streams {
      resetGridLiveCellVisuals()
      AppState.shared.streams = newStreams
    } else {
      UIView.animate(
        withDuration: 0.2, delay: 0,
        options: [.allowUserInteraction, .beginFromCurrentState]
      ) {
        self.resetGridLiveCellVisuals()
      }
    }

    fadeOutDragSnapshot(snapshot, finalFrame: finalSnapshotFrame)
  }

  private func currentGridSlotFrames(for streams: [StreamItem]) -> [CGRect] {
    streams.compactMap { stream in
      guard let cell = cellPool[stream.id] else { return nil }
      return cell.convert(cell.bounds, to: view)
    }
  }

  private func gridLiveInsertIndex(at location: CGPoint) -> Int {
    guard !gridDragSlotFrames.isEmpty else { return 0 }
    for (index, frame) in gridDragSlotFrames.enumerated() {
      if location.y < frame.minY { return index }
      if location.y <= frame.maxY {
        let isFullWidthSlot = frame.width >= view.bounds.width * 0.72
        if isFullWidthSlot {
          if location.y < frame.midY { return index }
        } else if location.x < frame.midX {
          return index
        }
      }
    }
    return gridDragSlotFrames.count
  }

  private func streams(moving sourceStream: StreamItem, to rawInsertIndex: Int) -> [StreamItem] {
    var next = AppState.shared.streams
    guard let sourceIndex = next.firstIndex(where: { $0.id == sourceStream.id }) else { return next }
    let moved = next.remove(at: sourceIndex)
    let adjustedInsertIndex = sourceIndex < rawInsertIndex ? rawInsertIndex - 1 : rawInsertIndex
    next.insert(moved, at: max(0, min(adjustedInsertIndex, next.count)))
    return next
  }

  private func applyGridLiveTransforms(for streams: [StreamItem]) {
    for stream in AppState.shared.streams {
      guard let cell = cellPool[stream.id], cell !== dragSourceCell,
            let originalFrame = gridDragOriginalFrames[stream.id],
            let targetIndex = streams.firstIndex(where: { $0.id == stream.id }),
            gridDragSlotFrames.indices.contains(targetIndex) else { continue }
      cell.transform = gridTransform(from: originalFrame, to: gridDragSlotFrames[targetIndex])
    }
  }

  private func gridTransform(from originalFrame: CGRect, to targetFrame: CGRect) -> CGAffineTransform {
    guard originalFrame.width > 0, originalFrame.height > 0 else { return .identity }
    return CGAffineTransform(
      a: targetFrame.width / originalFrame.width,
      b: 0,
      c: 0,
      d: targetFrame.height / originalFrame.height,
      tx: targetFrame.midX - originalFrame.midX,
      ty: targetFrame.midY - originalFrame.midY
    )
  }

  private func gridFinalSnapshotFrame(for sourceStream: StreamItem?, in streams: [StreamItem]?) -> CGRect? {
    guard let sourceStream, let streams,
          let targetIndex = streams.firstIndex(where: { $0.id == sourceStream.id }),
          gridDragSlotFrames.indices.contains(targetIndex) else { return nil }
    return gridDragSlotFrames[targetIndex]
  }

  private func resetGridLiveCellVisuals() {
    cellPool.values.forEach { cell in
      cell.alpha = 1
      cell.transform = .identity
    }
  }

  // MARK: - スタックモードのライブ並べ替え(iOSホーム画面のように他セルがリアルタイムに退く)

  private func beginLiveReorder(cell: StreamCellView, at location: CGPoint) {
    guard dragSnapshot == nil else { return }
    beginDragSnapshot(for: cell, at: location)
  }

  private func updateLiveReorder(at location: CGPoint) {
    guard let cell = dragSourceCell, updateDragSnapshot(at: location) else { return }

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
    let cell = dragSourceCell
    let newStreams = (commit && cell != nil) ? streamsFromLiveLayout() : nil
    let snapshot = clearDragState()

    cell?.alpha = 1
    fadeOutDragSnapshot(snapshot)

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
