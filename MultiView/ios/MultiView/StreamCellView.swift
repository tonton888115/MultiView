import UIKit
import WebKit

struct StreamReorderEvent {
  enum Phase: Equatable {
    case began
    case changed
    case ended
    case cancelled
  }

  let phase: Phase
  let windowLocation: CGPoint
}

final class StreamCellView: UIView, UIGestureRecognizerDelegate, UITextFieldDelegate, PlaybackStoppable {
  let stream: StreamItem
  private let onReorder: (StreamCellView, StreamReorderEvent) -> Void
  private var autoHider: AutoHidingControls?
  private let reorderHandle = ReorderHandleView()
  private let commentBar = UIView()
  private let commentField = UITextField()
  private let commentStatus = UILabel()
  private var viewerCountOverlay: ViewerCountOverlay?
  private var commentBottom: NSLayoutConstraint?
  private weak var commentPoster: CommentPostable?
  private weak var commentEchoer: CommentEchoDisplay?
  private weak var playbackView: PlaybackStoppable?

  init(stream: StreamItem, onFocus: @escaping () -> Void, onReorder: @escaping (StreamCellView, StreamReorderEvent) -> Void) {
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
    playbackView = video as? PlaybackStoppable
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
    if AppState.shared.settings.showViewerCount {
      let viewerCount = ViewerCountOverlay(stream: stream)
      viewerCount.translatesAutoresizingMaskIntoConstraints = false
      addSubview(viewerCount)
      viewerCountOverlay = viewerCount
    }

    let comment = UIButton(type: .system)
    comment.setImage(UIImage(systemName: "text.bubble"), for: .normal)
    comment.tintColor = .white
    comment.backgroundColor = UIColor.black.withAlphaComponent(0.38)
    comment.layer.cornerRadius = 16
    comment.addAction(UIAction { [weak self] _ in self?.toggleCommentBar() }, for: .touchUpInside)
    comment.translatesAutoresizingMaskIntoConstraints = false
    addSubview(comment)

    buildCommentBar()
    configureReorderHandle()

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
      volume.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.62),
      reorderHandle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      reorderHandle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      reorderHandle.widthAnchor.constraint(equalToConstant: 44),
      reorderHandle.heightAnchor.constraint(equalToConstant: 32)
    ])
    if let viewerCountOverlay {
      NSLayoutConstraint.activate([
        viewerCountOverlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
        viewerCountOverlay.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
      ])
    }
    var autoHideControls: [UIView] = [focus, remove, comment, volume, reorderHandle]
    if let viewerCountOverlay {
      autoHideControls.append(viewerCountOverlay)
    }
    autoHider = AutoHidingControls(host: self, controls: autoHideControls)
    let reorder = UILongPressGestureRecognizer(target: self, action: #selector(handleReorderGesture(_:)))
    reorder.minimumPressDuration = 0.28
    reorder.allowableMovement = 18
    reorder.cancelsTouchesInView = false
    reorder.delaysTouchesBegan = false
    reorder.delegate = self
    addGestureRecognizer(reorder)
  }

  private func configureReorderHandle() {
    reorderHandle.translatesAutoresizingMaskIntoConstraints = false
    reorderHandle.backgroundColor = UIColor.black.withAlphaComponent(0.46)
    reorderHandle.layer.cornerRadius = 14
    reorderHandle.layer.borderWidth = 1
    reorderHandle.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
    reorderHandle.accessibilityLabel = "並び替え"
    reorderHandle.accessibilityHint = "ドラッグして表示順を変更"
    reorderHandle.isAccessibilityElement = true
    reorderHandle.onDrag = { [weak self] event in
      guard let self else { return }
      if event.phase == .began {
        self.autoHider?.showTemporarily()
      }
      self.onReorder(self, event)
    }
    addSubview(reorderHandle)

    let icon = UIImageView(image: UIImage(systemName: "line.3.horizontal"))
    icon.tintColor = .white
    icon.contentMode = .scaleAspectFit
    icon.translatesAutoresizingMaskIntoConstraints = false
    reorderHandle.addSubview(icon)
    NSLayoutConstraint.activate([
      icon.centerXAnchor.constraint(equalTo: reorderHandle.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: reorderHandle.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 22),
      icon.heightAnchor.constraint(equalToConstant: 16)
    ])
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

  // 再利用プールから外れる(配信が消える/全体を作り直す)ときに内部プレイヤーを停止する。
  func stopPlayback() {
    playbackView?.stopPlayback()
  }

  @objc private func handleReorderGesture(_ gesture: UIGestureRecognizer) {
    guard let event = StreamReorderEvent(gesture: gesture, window: window) else { return }
    onReorder(self, event)
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
      if view === reorderHandle { return false }
      if view is UIControl { return false }
      current = view.superview
    }
    return true
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    true
  }

  private var dragVisualCanChange: Bool {
    alpha > 0.8
  }
}

private extension StreamReorderEvent {
  init?(gesture: UIGestureRecognizer, window: UIWindow?) {
    let phase: Phase
    switch gesture.state {
    case .began:
      phase = .began
    case .changed:
      phase = .changed
    case .ended:
      phase = .ended
    case .cancelled, .failed:
      phase = .cancelled
    default:
      return nil
    }
    let location = window.map { gesture.location(in: $0) } ?? gesture.location(in: nil)
    self.init(phase: phase, windowLocation: location)
  }
}

private final class ReorderHandleView: UIView {
  var onDrag: ((StreamReorderEvent) -> Void)?
  private var activeTouch: UITouch?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isMultipleTouchEnabled = false
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.insetBy(dx: -8, dy: -8).contains(point)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard activeTouch == nil, let touch = touches.first else { return }
    activeTouch = touch
    emit(.began, touch: touch)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = activeTouch, touches.contains(where: { $0 === touch }) else { return }
    emit(.changed, touch: touch)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = activeTouch, touches.contains(where: { $0 === touch }) else { return }
    emit(.ended, touch: touch)
    activeTouch = nil
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = activeTouch, touches.contains(where: { $0 === touch }) else { return }
    emit(.cancelled, touch: touch)
    activeTouch = nil
  }

  private func emit(_ phase: StreamReorderEvent.Phase, touch: UITouch) {
    let location = window.map { touch.location(in: $0) } ?? touch.location(in: nil)
    onDrag?(StreamReorderEvent(phase: phase, windowLocation: location))
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
