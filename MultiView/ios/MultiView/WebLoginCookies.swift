import Foundation
import WebKit

// Copies the logins made in the in-app web views (WKWebsiteDataStore) into the
// shared HTTPCookieStorage that the native URLSession players use. WKWebView and
// URLSession keep separate cookie jars, so without this a fresh web login is not
// seen by the native fetch until much later (the "permission error until reload"
// the user hit). Run it proactively so native playback uses the latest session.
enum WebLoginCookies {
  private static let domains = ["nicovideo.jp", "kick.com", "twitch.tv", "twitcasting.tv", "youtube.com", "google.com"]
  private static let snapshotKey = "web.login.cookies.snapshot.v1"

  static func sync(_ completion: (() -> Void)? = nil) {
    let store = WKWebsiteDataStore.default().httpCookieStore
    store.getAllCookies { cookies in
      let loginCookies = cookies.filter { cookie in
        domains.contains(where: { cookie.domain.contains($0) })
      }
      for cookie in loginCookies {
        HTTPCookieStorage.shared.setCookie(cookie)
      }
      saveSnapshot(loginCookies)
      DispatchQueue.main.async { completion?() }
    }
  }

  static func restore(_ completion: (() -> Void)? = nil) {
    let cookies = loadSnapshot()
    guard !cookies.isEmpty else {
      DispatchQueue.main.async { completion?() }
      return
    }
    let store = WKWebsiteDataStore.default().httpCookieStore
    let group = DispatchGroup()
    for cookie in cookies {
      HTTPCookieStorage.shared.setCookie(cookie)
      group.enter()
      store.setCookie(cookie) {
        group.leave()
      }
    }
    group.notify(queue: .main) {
      completion?()
    }
  }

  static func clearAll(completion: @escaping () -> Void) {
    UserDefaults.standard.removeObject(forKey: snapshotKey)
    if let cookies = HTTPCookieStorage.shared.cookies {
      cookies
        .filter { cookie in domains.contains(where: { cookie.domain.contains($0) }) }
        .forEach { HTTPCookieStorage.shared.deleteCookie($0) }
    }
    let store = WKWebsiteDataStore.default()
    store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
      let targets = records.filter { record in
        let name = record.displayName.lowercased()
        return domains.contains(where: { domain in
          let bare = domain
            .replacingOccurrences(of: ".jp", with: "")
            .replacingOccurrences(of: ".com", with: "")
          return name.contains(domain) || name.contains(bare)
        })
      }
      store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: targets) {
        DispatchQueue.main.async { completion() }
      }
    }
  }

  static func hasCookie(named name: String, domainContains domain: String) -> Bool {
    if HTTPCookieStorage.shared.cookies?.contains(where: {
      $0.name == name && !$0.value.isEmpty && $0.domain.contains(domain)
    }) == true {
      return true
    }
    return loadSnapshot().contains {
      $0.name == name && !$0.value.isEmpty && $0.domain.contains(domain)
    }
  }

  private static func saveSnapshot(_ cookies: [HTTPCookie]) {
    guard !cookies.isEmpty else { return }
    let merged = (loadSnapshot() + cookies).reduce(into: [String: HTTPCookie]()) { result, cookie in
      let key = "\(cookie.domain)|\(cookie.path)|\(cookie.name)"
      result[key] = cookie
    }.values
    let rows = merged.compactMap { cookie -> [String: Any]? in
      var row: [String: Any] = [
        "name": cookie.name,
        "value": cookie.value,
        "domain": cookie.domain,
        "path": cookie.path,
        "secure": cookie.isSecure
      ]
      if let expires = cookie.expiresDate {
        row["expires"] = expires.timeIntervalSince1970
      }
      return row
    }
    UserDefaults.standard.set(rows, forKey: snapshotKey)
  }

  private static func loadSnapshot() -> [HTTPCookie] {
    guard let rows = UserDefaults.standard.array(forKey: snapshotKey) as? [[String: Any]] else { return [] }
    return rows.compactMap { row in
      guard let name = row["name"] as? String,
            let value = row["value"] as? String,
            let domain = row["domain"] as? String,
            let path = row["path"] as? String else { return nil }
      var props: [HTTPCookiePropertyKey: Any] = [
        .name: name,
        .value: value,
        .domain: domain,
        .path: path
      ]
      if let secure = row["secure"] as? Bool, secure {
        props[.secure] = "TRUE"
      }
      if let expires = row["expires"] as? TimeInterval {
        props[.expires] = Date(timeIntervalSince1970: expires)
      }
      return HTTPCookie(properties: props)
    }
  }
}
