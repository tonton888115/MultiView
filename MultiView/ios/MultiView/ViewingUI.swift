import UIKit
import WebKit
import AVFoundation
import Network
import ImageIO
import AuthenticationServices
import Security
import CryptoKit

// Viewing UI: the grid/stacked ViewingController, per-stream StreamCellView, the
// VolumeOverlay, and the focused single-stream FocusedStreamView. Extracted from AppDelegate.swift.

final class ViewingController: UIViewController {
  private let scrollView = UIScrollView()
  private let stack = UIStackView()
  private var focused: StreamItem?
  private weak var dragSourceCell: StreamCellView?
  private weak var dragTargetCell: StreamCellView?
  private let reorderIndicator = UIView()
  private var dragSnapshot: UIView?
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

  private func handleReorder(cell: StreamCellView, gesture: UILongPressGestureRecognizer) {
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
    snapshot.frame = cell.convert(cell.bounds, to: view)
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
    dragSnapshot?.center = location
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
    var next = AppState.shared.streams
    let moved = next.remove(at: from)
    let adjustedInsertIndex = from < insertIndex ? insertIndex - 1 : insertIndex
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

final class StreamCellView: UIView, UIGestureRecognizerDelegate, UITextFieldDelegate {
  let stream: StreamItem
  private let onReorder: (StreamCellView, UILongPressGestureRecognizer) -> Void
  private var autoHider: AutoHidingControls?
  private let commentBar = UIView()
  private let commentField = UITextField()
  private let commentStatus = UILabel()
  private var commentBottom: NSLayoutConstraint?
  private weak var commentPoster: CommentPostable?
  private weak var commentEchoer: CommentEchoDisplay?

  init(stream: StreamItem, onFocus: @escaping () -> Void, onReorder: @escaping (StreamCellView, UILongPressGestureRecognizer) -> Void) {
    self.stream = stream
    self.onReorder = onReorder
    super.init(frame: .zero)
    backgroundColor = .black
    clipsToBounds = true
    layer.cornerRadius = 18
    layer.borderWidth = 0.5
    layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor

    let video: UIView
    if stream.platform == .niconico {
      video = NiconicoNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else if stream.platform == .kick {
      video = KickNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else if stream.platform == .twitch {
      video = TwitchNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else if stream.platform == .twitcasting {
      video = TwitcastingNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else if stream.platform == .youtube {
      video = YouTubeNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else {
      video = PlayerWebView(stream: stream, settings: AppState.shared.settings)
    }
    let audio = video as? AudioControllable
    commentPoster = video as? CommentPostable
    commentEchoer = video as? CommentEchoDisplay
    video.translatesAutoresizingMaskIntoConstraints = false
    addSubview(video)

    let focus = UIButton(type: .system)
    focus.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right"), for: .normal)
    focus.tintColor = .white
    focus.backgroundColor = UIColor.black.withAlphaComponent(0.38)
    focus.layer.cornerRadius = 16
    focus.addAction(UIAction { _ in onFocus() }, for: .touchUpInside)
    focus.translatesAutoresizingMaskIntoConstraints = false
    addSubview(focus)

    let remove = UIButton(type: .system)
    remove.setImage(UIImage(systemName: "xmark"), for: .normal)
    remove.tintColor = .white
    remove.backgroundColor = UIColor.black.withAlphaComponent(0.38)
    remove.layer.cornerRadius = 16
    remove.addAction(UIAction { _ in AppState.shared.remove(stream) }, for: .touchUpInside)
    remove.translatesAutoresizingMaskIntoConstraints = false
    addSubview(remove)

    let volume = VolumeOverlay(stream: stream) { value in
      audio?.setPlaybackVolume(value)
    }
    volume.translatesAutoresizingMaskIntoConstraints = false
    addSubview(volume)

    let comment = UIButton(type: .system)
    comment.setImage(UIImage(systemName: "text.bubble"), for: .normal)
    comment.tintColor = .white
    comment.backgroundColor = UIColor.black.withAlphaComponent(0.38)
    comment.layer.cornerRadius = 16
    comment.addAction(UIAction { [weak self] _ in self?.toggleCommentBar() }, for: .touchUpInside)
    comment.translatesAutoresizingMaskIntoConstraints = false
    addSubview(comment)

    buildCommentBar()

    NSLayoutConstraint.activate([
      video.topAnchor.constraint(equalTo: topAnchor),
      video.leadingAnchor.constraint(equalTo: leadingAnchor),
      video.trailingAnchor.constraint(equalTo: trailingAnchor),
      video.bottomAnchor.constraint(equalTo: bottomAnchor),
      focus.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      focus.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -8),
      focus.widthAnchor.constraint(equalToConstant: 32),
      focus.heightAnchor.constraint(equalToConstant: 32),
      remove.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      remove.widthAnchor.constraint(equalToConstant: 32),
      remove.heightAnchor.constraint(equalToConstant: 32),
      comment.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      comment.trailingAnchor.constraint(equalTo: focus.leadingAnchor, constant: -8),
      comment.widthAnchor.constraint(equalToConstant: 32),
      comment.heightAnchor.constraint(equalToConstant: 32),
      volume.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      volume.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      volume.widthAnchor.constraint(equalToConstant: 42),
      volume.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.62)
    ])
    autoHider = AutoHidingControls(host: self, controls: [focus, remove, comment, volume])
    let reorder = UILongPressGestureRecognizer(target: self, action: #selector(handleReorderGesture(_:)))
    reorder.minimumPressDuration = 0.45
    reorder.delegate = self
    addGestureRecognizer(reorder)
  }

  private func buildCommentBar() {
    commentBar.translatesAutoresizingMaskIntoConstraints = false
    commentBar.backgroundColor = UIColor.black.withAlphaComponent(0.6)
    commentBar.isHidden = true
    addSubview(commentBar)

    commentStatus.font = .systemFont(ofSize: 11)
    commentStatus.textColor = UIColor.white.withAlphaComponent(0.85)
    commentStatus.numberOfLines = 1
    commentStatus.isHidden = true
    commentStatus.translatesAutoresizingMaskIntoConstraints = false
    commentBar.addSubview(commentStatus)

    commentField.placeholder = "コメント"
    commentField.font = .systemFont(ofSize: 13)
    commentField.textColor = .white
    commentField.backgroundColor = UIColor.white.withAlphaComponent(0.14)
    commentField.layer.cornerRadius = 8
    commentField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
    commentField.leftViewMode = .always
    commentField.returnKeyType = .send
    commentField.autocorrectionType = .no
    commentField.delegate = self
    commentField.translatesAutoresizingMaskIntoConstraints = false
    commentBar.addSubview(commentField)

    let send = UIButton(type: .system)
    send.setImage(UIImage(systemName: "paperplane.fill"), for: .normal)
    send.tintColor = .systemBlue
    send.addAction(UIAction { [weak self] _ in self?.submitComment() }, for: .touchUpInside)
    send.translatesAutoresizingMaskIntoConstraints = false
    commentBar.addSubview(send)

    let bottom = commentBar.bottomAnchor.constraint(equalTo: bottomAnchor)
    commentBottom = bottom
    NSLayoutConstraint.activate([
      commentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
      commentBar.trailingAnchor.constraint(equalTo: trailingAnchor),
      bottom,
      commentBar.heightAnchor.constraint(equalToConstant: 46),
      commentStatus.leadingAnchor.constraint(equalTo: commentBar.leadingAnchor, constant: 12),
      commentStatus.topAnchor.constraint(equalTo: commentBar.topAnchor, constant: 3),
      commentField.leadingAnchor.constraint(equalTo: commentBar.leadingAnchor, constant: 10),
      commentField.bottomAnchor.constraint(equalTo: commentBar.bottomAnchor, constant: -8),
      commentField.heightAnchor.constraint(equalToConstant: 30),
      send.leadingAnchor.constraint(equalTo: commentField.trailingAnchor, constant: 8),
      send.trailingAnchor.constraint(equalTo: commentBar.trailingAnchor, constant: -10),
      send.centerYAnchor.constraint(equalTo: commentField.centerYAnchor),
      send.widthAnchor.constraint(equalToConstant: 30)
    ])
    NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
  }

  @objc private func keyboardWillChange(_ note: Notification) {
    guard commentField.isFirstResponder,
          let window,
          let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
    let keyboardTop = value.cgRectValue.minY
    let cellInWindow = convert(bounds, to: window)
    let overlap = cellInWindow.maxY - keyboardTop
    commentBottom?.constant = overlap > 0 ? -overlap : 0
    UIView.animate(withDuration: 0.2) { self.superview?.layoutIfNeeded() }
  }

  @objc private func keyboardWillHide() {
    commentBottom?.constant = 0
    UIView.animate(withDuration: 0.2) { self.superview?.layoutIfNeeded() }
  }

  private func toggleCommentBar() {
    setCommentBar(visible: commentBar.isHidden)
  }

  private func setCommentBar(visible: Bool) {
    commentBar.isHidden = !visible
    if visible {
      commentField.becomeFirstResponder()
    } else {
      commentField.resignFirstResponder()
    }
  }

  private func submitComment() {
    let text = commentField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else { return }
    guard let poster = commentPoster else {
      // No native posting for this platform yet — the expanded view can post via
      // the logged-in chat web.
      showCommentStatus("拡大(⤢)してコメントを送信できます")
      return
    }
    showCommentStatus("送信中…")
    poster.postComment(text) { [weak self] result in
      switch result {
      case .success:
        self?.commentField.text = ""
        self?.commentEchoer?.emitOwnComment(text)
        self?.showCommentStatus("送信しました")
        self?.setCommentBar(visible: false)
      case .failure(let error):
        self?.showCommentStatus(error.localizedDescription)
      }
    }
  }

  private func showCommentStatus(_ text: String) {
    commentStatus.text = text
    commentStatus.isHidden = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
      self?.commentStatus.isHidden = true
    }
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    submitComment()
    return true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func handleReorderGesture(_ gesture: UILongPressGestureRecognizer) {
    onReorder(self, gesture)
  }

  func setReorderSourceActive(_ active: Bool) {
    alpha = active ? 0.42 : 1
    layer.borderWidth = active ? 2 : 0.5
    layer.borderColor = (active ? UIColor.systemYellow : UIColor.white.withAlphaComponent(0.18)).cgColor
  }

  func setDropTargetActive(_ active: Bool) {
    guard dragVisualCanChange else { return }
    layer.borderWidth = active ? 2 : 0.5
    layer.borderColor = (active ? UIColor.systemGreen : UIColor.white.withAlphaComponent(0.18)).cgColor
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    var current: UIView? = touch.view
    while let view = current {
      if view is UIControl { return false }
      current = view.superview
    }
    return true
  }

  private var dragVisualCanChange: Bool {
    alpha > 0.8
  }
}

final class VolumeOverlay: UIVisualEffectView {
  init(stream: StreamItem, onChange: @escaping (Float) -> Void) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      super.init(effect: UIGlassEffect())
    } else {
      super.init(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    }
    #else
    super.init(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    #endif
    clipsToBounds = true
    layer.cornerRadius = 18

    let icon = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
    icon.tintColor = .white
    icon.contentMode = .scaleAspectFit
    icon.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(icon)

    let slider = UISlider()
    slider.minimumValue = 0
    slider.maximumValue = 1
    slider.value = StreamVolumeStore.volume(for: stream)
    slider.minimumTrackTintColor = stream.platform.tint
    slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.28)
    slider.addAction(UIAction { action in
      guard let slider = action.sender as? UISlider else { return }
      StreamVolumeStore.setVolume(slider.value, for: stream)
      onChange(slider.value)
    }, for: .valueChanged)
    let thumbSize: CGFloat = 15
    let thumb = UIGraphicsImageRenderer(size: CGSize(width: thumbSize, height: thumbSize)).image { context in
      UIColor.white.setFill()
      context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: thumbSize, height: thumbSize))
    }
    slider.setThumbImage(thumb, for: .normal)
    slider.setThumbImage(thumb, for: .highlighted)
    slider.transform = CGAffineTransform(rotationAngle: -.pi / 2)
    slider.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(slider)

    NSLayoutConstraint.activate([
      icon.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      icon.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
      icon.widthAnchor.constraint(equalToConstant: 18),
      icon.heightAnchor.constraint(equalToConstant: 18),
      slider.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      slider.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -8),
      slider.widthAnchor.constraint(equalTo: contentView.heightAnchor, constant: -34),
      slider.heightAnchor.constraint(equalToConstant: 24)
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class FocusedStreamView: UIView {
  private let stream: StreamItem
  private let chatWeb: WKWebView?
  private let input = UITextField()
  private var autoHider: AutoHidingControls?
  private weak var commentPoster: CommentPostable?
  private weak var commentEchoer: CommentEchoDisplay?

  init(stream: StreamItem, onClose: (() -> Void)?) {
    self.stream = stream
    let chatURL = FocusedStreamView.chatURL(for: stream)
    if let chatURL {
      let config = WKWebViewConfiguration()
      config.allowsInlineMediaPlayback = true
      config.websiteDataStore = .default()
      WebAdBlocker.install(on: config)
      chatWeb = WKWebView(frame: .zero, configuration: config)
      // YouTube の live_chat 埋め込みはモバイルWeb非対応で、WKWebView標準UA(モバイル)では
      // 「チャットをご利用いただけません。ブラウザのバージョンが古いようです」と出て表示されない。
      // デスクトップ Safari の UA を名乗るとデスクトップ版 live_chat が返り、正しく表示される。
      if stream.platform == .youtube {
        chatWeb?.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
      }
      // 読み込みは super.init 後に少し遅らせて開始する（下記）。展開直後はネイティブ
      // プレイヤーの起動を優先し、重いチャット watch ページと帯域を奪い合わせない。
    } else {
      chatWeb = nil
    }
    super.init(frame: .zero)
    backgroundColor = .black
    // 展開直後の主役は映像。重いチャット watch ページの読み込みは僅かに遅らせ、ネイティブ
    // プレイヤーの起動（クッキー同期→watchページ取得→HLSバッファ）に帯域/CPUを先に使わせる。
    // 体感では即時に近いが、起動時の通信競合を避けて初回フレーム表示を早める。
    if let chatURL {
      let request = URLRequest(url: chatURL)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        self?.chatWeb?.load(request)
      }
    }
    // 高さは ViewingController 側で可視領域いっぱいに設定する。ここでは最低限のフロアだけ
    // （必須より低い優先度なので、全画面表示の equalTo 制約と衝突しない）。
    let minHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: 320)
    minHeight.priority = UILayoutPriority(749)
    minHeight.isActive = true

    let video: UIView
    if stream.platform == .niconico {
      video = NiconicoNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else if stream.platform == .kick {
      video = KickNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else if stream.platform == .twitch {
      video = TwitchNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else if stream.platform == .twitcasting {
      video = TwitcastingNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else if stream.platform == .youtube {
      video = YouTubeNativePlayerView(stream: stream, settings: AppState.shared.settings)
    } else {
      video = PlayerWebView(stream: stream, settings: AppState.shared.settings)
    }
    let audio = video as? AudioControllable
    commentPoster = video as? CommentPostable
    commentEchoer = video as? CommentEchoDisplay
    video.translatesAutoresizingMaskIntoConstraints = false
    addSubview(video)

    var closeButton: UIButton?
    if let onClose {
      let close = UIButton(type: .system)
      close.setImage(UIImage(systemName: "chevron.left"), for: .normal)
      close.tintColor = .white
      close.backgroundColor = UIColor.black.withAlphaComponent(0.38)
      close.layer.cornerRadius = 18
      close.addAction(UIAction { _ in onClose() }, for: .touchUpInside)
      close.translatesAutoresizingMaskIntoConstraints = false
      addSubview(close)
      closeButton = close
    }

    let remove = UIButton(type: .system)
    remove.setImage(UIImage(systemName: "xmark"), for: .normal)
    remove.tintColor = .white
    remove.backgroundColor = UIColor.black.withAlphaComponent(0.38)
    remove.layer.cornerRadius = 18
    remove.addAction(UIAction { _ in AppState.shared.remove(stream) }, for: .touchUpInside)
    remove.translatesAutoresizingMaskIntoConstraints = false
    addSubview(remove)

    let volume = VolumeOverlay(stream: stream) { value in
      audio?.setPlaybackVolume(value)
    }
    volume.translatesAutoresizingMaskIntoConstraints = false
    addSubview(volume)

    let chatPanel = LiquidGlass.makePanel(cornerRadius: 18)
    chatPanel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(chatPanel)

    if let chatWeb {
      chatWeb.translatesAutoresizingMaskIntoConstraints = false
      chatPanel.contentView.addSubview(chatWeb)
    } else {
      let label = UILabel()
      label.text = "このサービスはチャット入力未対応です"
      label.textColor = .secondaryLabel
      label.textAlignment = .center
      label.translatesAutoresizingMaskIntoConstraints = false
      chatPanel.contentView.addSubview(label)
      NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: chatPanel.contentView.centerXAnchor),
        label.centerYAnchor.constraint(equalTo: chatPanel.contentView.centerYAnchor)
      ])
    }

    input.placeholder = "コメント"
    input.textColor = .white
    input.backgroundColor = UIColor.white.withAlphaComponent(0.1)
    input.layer.cornerRadius = 14
    input.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
    input.leftViewMode = .always
    input.translatesAutoresizingMaskIntoConstraints = false
    addSubview(input)

    let send = UIButton(type: .system)
    send.setTitle("送信", for: .normal)
    send.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
    send.addAction(UIAction { [weak self] _ in self?.sendComment() }, for: .touchUpInside)
    send.translatesAutoresizingMaskIntoConstraints = false
    addSubview(send)

    // 拡大表示は「ブラウザ(チャット)を大きく上に・プレイヤーを小さく下に」配置する。
    // 以前は逆 (プレイヤー全面＋下にチャット小窓) で、チャットが小さく見にくかった。
    var constraints: [NSLayoutConstraint] = [
      chatPanel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      chatPanel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      chatPanel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      chatPanel.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -8),
      input.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      input.bottomAnchor.constraint(equalTo: video.topAnchor, constant: -8),
      input.heightAnchor.constraint(equalToConstant: 40),
      send.leadingAnchor.constraint(equalTo: input.trailingAnchor, constant: 8),
      send.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      send.centerYAnchor.constraint(equalTo: input.centerYAnchor),
      send.widthAnchor.constraint(equalToConstant: 54),
      video.leadingAnchor.constraint(equalTo: leadingAnchor),
      video.trailingAnchor.constraint(equalTo: trailingAnchor),
      video.bottomAnchor.constraint(equalTo: bottomAnchor),
      video.heightAnchor.constraint(equalTo: widthAnchor, multiplier: 9.0 / 16.0),
      remove.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      remove.widthAnchor.constraint(equalToConstant: 36),
      remove.heightAnchor.constraint(equalToConstant: 36),
      volume.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      volume.centerYAnchor.constraint(equalTo: video.centerYAnchor),
      volume.widthAnchor.constraint(equalToConstant: 42),
      volume.heightAnchor.constraint(equalTo: video.heightAnchor, multiplier: 0.7)
    ]
    if let closeButton {
      constraints += [
        closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 10),
        closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
        closeButton.widthAnchor.constraint(equalToConstant: 36),
        closeButton.heightAnchor.constraint(equalToConstant: 36)
      ]
    }
    if let chatWeb {
      constraints += [
        chatWeb.topAnchor.constraint(equalTo: chatPanel.contentView.topAnchor),
        chatWeb.leadingAnchor.constraint(equalTo: chatPanel.contentView.leadingAnchor),
        chatWeb.trailingAnchor.constraint(equalTo: chatPanel.contentView.trailingAnchor),
        chatWeb.bottomAnchor.constraint(equalTo: chatPanel.contentView.bottomAnchor)
      ]
    }
    NSLayoutConstraint.activate(constraints)
    // close/remove/volume は chatPanel より先に addSubview したため、上に来たチャットパネルに
    // 隠れて見えなくなる（×ボタンが出ない不具合）。操作ボタン群を最前面に出す。
    bringSubviewToFront(volume)
    bringSubviewToFront(remove)
    if let closeButton { bringSubviewToFront(closeButton) }
    var autoHideControls: [UIView] = [remove, volume]
    if let closeButton {
      autoHideControls.append(closeButton)
    }
    autoHider = AutoHidingControls(host: self, controls: autoHideControls)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func sendComment() {
    guard let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
    if let commentPoster {
      commentPoster.postComment(text) { [weak self] result in
        DispatchQueue.main.async {
          switch result {
          case .success:
            self?.input.text = ""
            self?.commentEchoer?.emitOwnComment(text)
          case .failure:
            self?.sendWebComment(text)
          }
        }
      }
      return
    }
    sendWebComment(text)
  }

  private func sendWebComment(_ text: String) {
    guard let chatWeb else { return }
    let escaped = text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'")
      .replacingOccurrences(of: "\n", with: " ")
    let script = """
    (function(){
      var el = document.querySelector('textarea, input[type=text], [contenteditable=true]');
      if (!el) return false;
      el.focus();
      if ('value' in el) {
        el.value = '\(escaped)';
        el.dispatchEvent(new Event('input', {bubbles:true}));
      } else {
        el.textContent = '\(escaped)';
        el.dispatchEvent(new InputEvent('input', {bubbles:true, data:'\(escaped)'}));
      }
      var submit = document.querySelector('button[type=submit], input[type=submit], button[aria-label*="Send"], button[aria-label*="送信"]');
      if (submit) submit.click();
      return true;
    })();
    """
    chatWeb.evaluateJavaScript(script)
    input.text = ""
  }

  private static func chatURL(for stream: StreamItem) -> URL? {
    let channel = stream.channel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stream.channel
    switch stream.platform {
    case .twitch:
      return URL(string: "https://www.twitch.tv/popout/\(channel)/chat?popout=")
    case .youtube:
      return URL(string: "https://www.youtube.com/live_chat?v=\(channel)&embed_domain=tonton888115.github.io")
    case .kick:
      return URL(string: "https://kick.com/\(channel)")
    case .twitcasting:
      return URL(string: "https://twitcasting.tv/\(channel)")
    case .niconico:
      return URL(string: "https://live.nicovideo.jp/watch/\(channel)")
    }
  }
}
