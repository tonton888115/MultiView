import UIKit
import WebKit

final class FocusedStreamView: UIView {
  private let stream: StreamItem
  private let chatWeb: WKWebView?
  private let input = UITextField()
  private var autoHider: AutoHidingControls?
  private weak var commentPoster: CommentPostable?
  private weak var commentEchoer: CommentEchoDisplay?
  private var viewerCountOverlay: ViewerCountOverlay?

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
        chatWeb?.customUserAgent = BrowserUserAgent.desktopSafari
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
    if AppState.shared.settings.showViewerCount {
      let viewerCount = ViewerCountOverlay(stream: stream)
      viewerCount.translatesAutoresizingMaskIntoConstraints = false
      addSubview(viewerCount)
      viewerCountOverlay = viewerCount
    }

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
    if let viewerCountOverlay {
      constraints += [
        viewerCountOverlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
        viewerCountOverlay.bottomAnchor.constraint(equalTo: video.bottomAnchor, constant: -10)
      ]
    }
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
    if let viewerCountOverlay { bringSubviewToFront(viewerCountOverlay) }
    var autoHideControls: [UIView] = [remove, volume]
    if let viewerCountOverlay {
      autoHideControls.append(viewerCountOverlay)
    }
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
