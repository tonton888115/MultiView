import UIKit
import WebKit

final class NiconicoWarmup: NSObject, WKNavigationDelegate {
  static let shared = NiconicoWarmup()

  private var webViews: [String: WKWebView] = [:]
  private var completions: [String: [() -> Void]] = [:]
  private var lastFinished: [String: Date] = [:]
  private var reloadCounts: [String: Int] = [:]

  func prewarm(programId rawProgramId: String, forceReload: Bool = false, completion: (() -> Void)? = nil) {
    let programId = rawProgramId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !programId.isEmpty,
          let url = URL(string: "https://live.nicovideo.jp/watch/\(programId)") else {
      completion?()
      return
    }
    if !forceReload, let last = lastFinished[programId], Date().timeIntervalSince(last) < 30 {
      WebLoginCookies.restore {
        WebLoginCookies.sync(completion)
      }
      return
    }
    if let completion {
      completions[programId, default: []].append(completion)
    }
    if let existing = webViews[programId] {
      reloadCounts[programId] = 0
      WebLoginCookies.restore {
        existing.load(URLRequest(url: url))
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
        self?.complete(programId: programId)
      }
      return
    }

    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    config.websiteDataStore = .default()
    WebAdBlocker.install(on: config)
    let web = WKWebView(frame: CGRect(x: -240, y: -240, width: 160, height: 160), configuration: config)
    web.customUserAgent = NiconicoNativePlayerView.userAgent
    web.navigationDelegate = self
    web.alpha = 0.01
    web.isUserInteractionEnabled = false
    web.accessibilityIdentifier = programId
    webViews[programId] = web
    reloadCounts[programId] = 0

    if let window = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow }) {
      web.frame = CGRect(x: 0, y: window.bounds.maxY - 1, width: 1, height: 1)
      window.addSubview(web)
    }
    WebLoginCookies.restore {
      web.load(URLRequest(url: url))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
      self?.complete(programId: programId)
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let programId = webView.accessibilityIdentifier else { return }
    let count = reloadCounts[programId] ?? 0
    guard count > 0 else {
      reloadCounts[programId] = count + 1
      WebLoginCookies.sync {
        WebLoginCookies.restore {
          webView.reload()
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
        self?.complete(programId: programId)
      }
      return
    }
    complete(programId: programId)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    complete(programId: webView.accessibilityIdentifier)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    complete(programId: webView.accessibilityIdentifier)
  }

  private func complete(programId: String?) {
    guard let programId, webViews[programId] != nil else { return }
    lastFinished[programId] = Date()
    let callbacks = completions.removeValue(forKey: programId) ?? []
    WebLoginCookies.sync {
      callbacks.forEach { $0() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
      guard let self,
            let last = self.lastFinished[programId],
            Date().timeIntervalSince(last) >= 90 else { return }
      self.webViews[programId]?.navigationDelegate = nil
      self.webViews[programId]?.stopLoading()
      self.webViews[programId]?.removeFromSuperview()
      self.webViews.removeValue(forKey: programId)
      self.lastFinished.removeValue(forKey: programId)
      self.reloadCounts.removeValue(forKey: programId)
    }
  }
}
