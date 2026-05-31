import UIKit
import AVFoundation
import CoreImage.CIFilterBuiltins

// デバイス間（iPad→iPhone 等）で「いま開いている視聴タブ一式」をワンタップ引き継ぎする。
// サイドロード/LiveContainer 配下では外部からの multiview:// 起動が確実に来ないため、
// 受信は必ずアプリ内で完結させる（QRスキャン or クリップボード貼付）。サーバ不要・即時・無認証。

// 転送ペイロード。id は端末間で無意味なので送らず、受信側で採番する。
struct HandoffPayload: Codable {
  struct Entry: Codable {
    let p: String   // StreamPlatform.rawValue
    let c: String   // channel
  }

  let v: Int
  let s: [Entry]
  let layout: String?

  static let currentVersion = 1
  static let urlScheme = "multiview"
  static let urlHost = "handoff"

  init(streams: [StreamItem], layout: LayoutMode) {
    self.v = Self.currentVersion
    self.s = streams.map { Entry(p: $0.platform.rawValue, c: $0.channel) }
    self.layout = layout.rawValue
  }

  // QR・コピー・共有すべてに使う生コード（base64(JSON)）。外部URL起動には依存しない。
  func encodedCode() -> String {
    guard let data = try? JSONEncoder().encode(self) else { return "" }
    return data.base64EncodedString()
  }

  // 生base64 でも multiview://handoff?d=... でも受け取れるようにしておく。
  static func decode(from raw: String) -> HandoffPayload? {
    var code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !code.isEmpty else { return nil }
    if let components = URLComponents(string: code),
       components.scheme == urlScheme,
       let d = components.queryItems?.first(where: { $0.name == "d" })?.value {
      code = d.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let data = Data(base64Encoded: code),
          let payload = try? JSONDecoder().decode(HandoffPayload.self, from: data),
          payload.v == currentVersion else { return nil }
    return payload
  }

  // 受信側で新規 id を採番して復元。
  func streamItems() -> [StreamItem] {
    s.compactMap { entry in
      guard let platform = StreamPlatform(rawValue: entry.p) else { return nil }
      let channel = entry.c.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !channel.isEmpty else { return nil }
      return StreamItem(id: UUID().uuidString, platform: platform, channel: channel)
    }
  }

  var layoutMode: LayoutMode? {
    layout.flatMap { LayoutMode(rawValue: $0) }
  }
}

enum HandoffQR {
  static func image(from string: String, side: CGFloat) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
    let scale = max(1, side / output.extent.width)
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let context = CIContext()
    guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cg)
  }
}

final class HandoffController: UIViewController {
  private let segmented = UISegmentedControl(items: ["送る", "受け取る"])
  private let sendStack = UIStackView()
  private let receiveStack = UIStackView()
  private let qrImageView = UIImageView()
  private let sendInfoLabel = UILabel()
  private let code = HandoffPayload(streams: AppState.shared.streams, layout: AppState.shared.settings.layoutMode).encodedCode()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = "引き継ぎ"
    navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(closeTapped))

    segmented.selectedSegmentIndex = AppState.shared.streams.isEmpty ? 1 : 0
    segmented.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
    segmented.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(segmented)

    buildSend()
    buildReceive()
    view.addSubview(sendStack)
    view.addSubview(receiveStack)

    NSLayoutConstraint.activate([
      segmented.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      segmented.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      segmented.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      sendStack.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 24),
      sendStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      sendStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
      receiveStack.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 24),
      receiveStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      receiveStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
    ])
    modeChanged()
  }

  private func buildSend() {
    sendStack.axis = .vertical
    sendStack.spacing = 16
    sendStack.alignment = .center
    sendStack.translatesAutoresizingMaskIntoConstraints = false

    let count = AppState.shared.streams.count
    sendInfoLabel.text = count > 0
      ? "この端末で開いている \(count) タブのQRです。\nもう一方の端末で MultiView →「引き継ぎ」→「受け取る」で読み取ってください。"
      : "開いているタブがありません。"
    sendInfoLabel.numberOfLines = 0
    sendInfoLabel.textAlignment = .center
    sendInfoLabel.font = .systemFont(ofSize: 13)
    sendInfoLabel.textColor = .secondaryLabel

    qrImageView.image = HandoffQR.image(from: code, side: 600)
    qrImageView.contentMode = .scaleAspectFit
    qrImageView.backgroundColor = .white
    qrImageView.layer.cornerRadius = 12
    qrImageView.layer.masksToBounds = true
    qrImageView.translatesAutoresizingMaskIntoConstraints = false
    qrImageView.widthAnchor.constraint(equalToConstant: 240).isActive = true
    qrImageView.heightAnchor.constraint(equalToConstant: 240).isActive = true
    qrImageView.isHidden = count == 0

    let copyButton = LiquidGlass.makeButton(title: "コードをコピー", systemImage: "doc.on.doc", tint: nil)
    copyButton.addAction(UIAction { [weak self] _ in self?.copyCode() }, for: .touchUpInside)
    let shareButton = LiquidGlass.makeButton(title: "共有 (AirDrop等)", systemImage: "square.and.arrow.up", tint: nil)
    // sender 経由で起点ビューを取る（クロージャが自ボタンを強参照してリークするのを避ける）。
    shareButton.addAction(UIAction { [weak self] action in
      guard let source = action.sender as? UIView else { return }
      self?.shareCode(from: source)
    }, for: .touchUpInside)

    sendStack.addArrangedSubview(sendInfoLabel)
    sendStack.addArrangedSubview(qrImageView)
    if count > 0 {
      sendStack.addArrangedSubview(copyButton)
      sendStack.addArrangedSubview(shareButton)
    }
  }

  private func buildReceive() {
    receiveStack.axis = .vertical
    receiveStack.spacing = 16
    receiveStack.alignment = .center
    receiveStack.translatesAutoresizingMaskIntoConstraints = false

    let info = UILabel()
    info.text = "もう一方の端末の「送る」QRを読み取るか、コピーしたコードを貼り付けて受け取ります。"
    info.numberOfLines = 0
    info.textAlignment = .center
    info.font = .systemFont(ofSize: 13)
    info.textColor = .secondaryLabel

    let scanButton = LiquidGlass.makeButton(title: "QRをスキャン", systemImage: "qrcode.viewfinder", tint: .systemBlue)
    scanButton.addAction(UIAction { [weak self] _ in self?.startScan() }, for: .touchUpInside)
    let pasteButton = LiquidGlass.makeButton(title: "クリップボードから受け取る", systemImage: "doc.on.clipboard", tint: nil)
    pasteButton.addAction(UIAction { [weak self] _ in self?.receiveFromClipboard() }, for: .touchUpInside)

    receiveStack.addArrangedSubview(info)
    receiveStack.addArrangedSubview(scanButton)
    receiveStack.addArrangedSubview(pasteButton)
  }

  @objc private func modeChanged() {
    let sending = segmented.selectedSegmentIndex == 0
    sendStack.isHidden = !sending
    receiveStack.isHidden = sending
  }

  @objc private func closeTapped() {
    dismiss(animated: true)
  }

  private func copyCode() {
    UIPasteboard.general.string = code
    toast("コードをコピーしました")
  }

  private func shareCode(from source: UIView) {
    let activity = UIActivityViewController(activityItems: [code], applicationActivities: nil)
    // iPad ではポップオーバーの起点が必須（無いとクラッシュ）。
    activity.popoverPresentationController?.sourceView = source
    activity.popoverPresentationController?.sourceRect = source.bounds
    present(activity, animated: true)
  }

  private func startScan() {
    let scanner = HandoffScannerController()
    scanner.onScan = { [weak self] scanned in
      self?.handleReceived(scanned)
    }
    let nav = UINavigationController(rootViewController: scanner)
    nav.modalPresentationStyle = .fullScreen
    present(nav, animated: true)
  }

  private func receiveFromClipboard() {
    guard let text = UIPasteboard.general.string, !text.isEmpty else {
      alert(title: "クリップボードが空です", message: "送る側で「コードをコピー」してから、もう一度試してください。")
      return
    }
    handleReceived(text)
  }

  private func handleReceived(_ raw: String) {
    guard let payload = HandoffPayload.decode(from: raw) else {
      alert(title: "受け取れませんでした", message: "コード/QRを認識できませんでした。送る側のQRかコピーしたコードか確認してください。")
      return
    }
    let items = payload.streamItems()
    guard !items.isEmpty else {
      alert(title: "タブが空です", message: "受け取れる視聴タブがありませんでした。")
      return
    }
    let sheet = UIAlertController(
      title: "\(items.count) タブを受け取りました",
      message: "この端末の視聴タブをどうしますか？",
      preferredStyle: .alert
    )
    sheet.addAction(UIAlertAction(title: "置き換える", style: .destructive) { [weak self] _ in
      self?.apply(payload, items: items, replace: true)
    })
    sheet.addAction(UIAlertAction(title: "追加する", style: .default) { [weak self] _ in
      self?.apply(payload, items: items, replace: false)
    })
    sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
    present(sheet, animated: true)
  }

  private func apply(_ payload: HandoffPayload, items: [StreamItem], replace: Bool) {
    if replace {
      if let layout = payload.layoutMode, layout != AppState.shared.settings.layoutMode {
        var settings = AppState.shared.settings
        settings.layoutMode = layout
        AppState.shared.settings = settings
      }
      AppState.shared.streams = items
    } else {
      items.forEach { AppState.shared.addIfNeeded(platform: $0.platform, channel: $0.channel) }
    }
    dismiss(animated: true)
  }

  private func toast(_ text: String) {
    let label = PaddingLabel()
    label.text = text
    label.textColor = .white
    label.backgroundColor = UIColor.black.withAlphaComponent(0.82)
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    label.layer.cornerRadius = 10
    label.layer.masksToBounds = true
    label.alpha = 0
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28)
    ])
    UIView.animate(withDuration: 0.2) { label.alpha = 1 }
    UIView.animate(withDuration: 0.3, delay: 1.6, options: []) {
      label.alpha = 0
    } completion: { _ in
      label.removeFromSuperview()
    }
  }

  private func alert(title: String, message: String) {
    let controller = UIAlertController(title: title, message: message, preferredStyle: .alert)
    controller.addAction(UIAlertAction(title: "OK", style: .default))
    present(controller, animated: true)
  }
}

private final class PaddingLabel: UILabel {
  override var intrinsicContentSize: CGSize {
    let base = super.intrinsicContentSize
    return CGSize(width: base.width + 28, height: base.height + 18)
  }
}

final class HandoffScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  var onScan: ((String) -> Void)?
  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "app.multiview.handoff.scanner")
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private var didFind = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    title = "QRをスキャン"
    navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
    requestCameraAndConfigure()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer?.frame = view.bounds
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    sessionQueue.async { [session] in
      if session.isRunning { session.stopRunning() }
    }
  }

  private func requestCameraAndConfigure() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      configureSession()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          if granted { self?.configureSession() } else { self?.showDenied() }
        }
      }
    default:
      showDenied()
    }
  }

  private func configureSession() {
    guard let device = AVCaptureDevice.default(for: .video),
          let input = try? AVCaptureDeviceInput(device: device),
          session.canAddInput(input) else {
      showUnavailable()
      return
    }
    session.addInput(input)
    let output = AVCaptureMetadataOutput()
    guard session.canAddOutput(output) else {
      showUnavailable()
      return
    }
    session.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: .main)
    output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []

    let preview = AVCaptureVideoPreviewLayer(session: session)
    preview.videoGravity = .resizeAspectFill
    preview.frame = view.bounds
    view.layer.insertSublayer(preview, at: 0)
    previewLayer = preview

    addHint()
    sessionQueue.async { [session] in
      if !session.isRunning { session.startRunning() }
    }
  }

  private func addHint() {
    let hint = UILabel()
    hint.text = "送る側のQRを枠に合わせてください"
    hint.textColor = .white
    hint.font = .systemFont(ofSize: 14, weight: .semibold)
    hint.textAlignment = .center
    hint.numberOfLines = 0
    hint.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hint)
    NSLayoutConstraint.activate([
      hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
      hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40)
    ])
  }

  func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
    guard !didFind,
          let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
          object.type == .qr,
          let value = object.stringValue,
          HandoffPayload.decode(from: value) != nil else { return }
    didFind = true
    sessionQueue.async { [session] in
      if session.isRunning { session.stopRunning() }
    }
    let onScan = onScan
    dismiss(animated: true) {
      onScan?(value)
    }
  }

  private func showDenied() {
    presentInfo(
      title: "カメラが許可されていません",
      message: "設定アプリ → MultiView でカメラを許可するか、送る側で「コードをコピー」して「クリップボードから受け取る」を使ってください。"
    )
  }

  private func showUnavailable() {
    presentInfo(title: "カメラを使用できません", message: "「クリップボードから受け取る」をお使いください。")
  }

  private func presentInfo(title: String, message: String) {
    let controller = UIAlertController(title: title, message: message, preferredStyle: .alert)
    controller.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
      self?.dismiss(animated: true)
    })
    present(controller, animated: true)
  }

  @objc private func cancelTapped() {
    dismiss(animated: true)
  }
}
