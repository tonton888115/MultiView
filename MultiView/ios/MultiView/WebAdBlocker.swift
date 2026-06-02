import WebKit

enum WebAdBlocker {
  private static let identifier = "MultiViewWebAdBlocker"
  private static var ruleList: WKContentRuleList?
  private static var isCompiling = false

  static func prepare() {
    guard Store.loadSettings().blockWebAds else { return }
    compileIfNeeded()
  }

  static func install(on configuration: WKWebViewConfiguration) {
    guard Store.loadSettings().blockWebAds else { return }
    if let ruleList {
      configuration.userContentController.add(ruleList)
      return
    }
    compileIfNeeded()
  }

  private static func compileIfNeeded() {
    guard !isCompiling, ruleList == nil else { return }
    isCompiling = true
    WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: identifier,
      encodedContentRuleList: rulesJSON
    ) { list, _ in
      isCompiling = false
      ruleList = list
    }
  }

  private static let rulesJSON = """
  [
    {"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","raw","media"],"if-domain":["doubleclick.net","googlesyndication.com","googleadservices.com","adservice.google.com","pagead2.googlesyndication.com","ads.youtube.com","imasdk.googleapis.com","pubads.g.doubleclick.net","securepubads.g.doubleclick.net","amazon-adsystem.com","adnxs.com","adsystem.com","taboola.com","outbrain.com"]},"action":{"type":"block"}}
  ]
  """
}
