import UIKit
import WebKit
import AVFoundation
import Network
import ImageIO
import AuthenticationServices
import Security
import CryptoKit

// OAuth: per-platform auth managers (Twitch / TwitCasting / YouTube), token keychain
// storage, live-chat DTOs and OAuth config types. Extracted from AppDelegate.swift.

struct SimpleOAuthToken: Codable {
  let accessToken: String
  let expiresAt: TimeInterval
  let userID: String?
  let refreshToken: String?

  // refreshToken defaults to nil so existing call sites (and old stored tokens that
  // predate this field) keep compiling/decoding unchanged.
  init(accessToken: String, expiresAt: TimeInterval, userID: String?, refreshToken: String? = nil) {
    self.accessToken = accessToken
    self.expiresAt = expiresAt
    self.userID = userID
    self.refreshToken = refreshToken
  }

  var isValid: Bool {
    Date().timeIntervalSince1970 < expiresAt
  }
}

enum OAuthKeychain {
  static func load(account: String, service: String = "com.rinng.multiview.oauth") -> SimpleOAuthToken? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else { return nil }
    return try? JSONDecoder().decode(SimpleOAuthToken.self, from: data)
  }

  static func save(_ token: SimpleOAuthToken?, account: String, service: String = "com.rinng.multiview.oauth") {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    SecItemDelete(base as CFDictionary)
    guard let token, let data = try? JSONEncoder().encode(token) else { return }
    var item = base
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(item as CFDictionary, nil)
  }
}

struct TwitchOAuthConfig: Codable {
  var clientId = ""
  // Twitch requires HTTPS redirect URIs. This hosted bridge forwards the OAuth
  // fragment back to the app's multiview:// custom scheme.
  var redirectURI = "https://tonton888115.github.io/MultiView/twitch-oauth.html"
}

final class TwitchAuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {
  static let shared = TwitchAuthManager()
  private let configKey = "twitch.oauth.config.v1"
  private let tokenAccount = "twitch"
  private var activeSession: ASWebAuthenticationSession?
  private var authAnchor: ASPresentationAnchor?
  private weak var deviceAuthAlert: UIAlertController?
  private var activeDeviceCode: String?
  private var devicePollWorkItem: DispatchWorkItem?
  private var refreshWaiters: [(Result<SimpleOAuthToken, Error>) -> Void] = []
  private var refreshInFlight = false

  var config: TwitchOAuthConfig {
    get {
      guard let data = UserDefaults.standard.data(forKey: configKey),
            var config = try? JSONDecoder().decode(TwitchOAuthConfig.self, from: data) else {
        return TwitchOAuthConfig()
      }
      if config.redirectURI.isEmpty || config.redirectURI.hasPrefix("multiview://") {
        config.redirectURI = TwitchOAuthConfig().redirectURI
        self.config = config
      }
      return config
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        UserDefaults.standard.set(data, forKey: configKey)
      }
    }
  }

  var isSignedIn: Bool {
    guard let token = OAuthKeychain.load(account: tokenAccount) else { return false }
    return token.isValid || token.refreshToken?.isEmpty == false
  }

  func signOut() {
    devicePollWorkItem?.cancel()
    devicePollWorkItem = nil
    activeDeviceCode = nil
    OAuthKeychain.save(nil, account: tokenAccount)
  }

  func signIn(presentationAnchor: ASPresentationAnchor?, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let presentationAnchor else {
      Self.finish(completion, .failure(OAuthServiceError.message("Twitch認証を開始できません")))
      return
    }
    let config = self.config
    guard !config.clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      Self.finish(completion, .failure(OAuthServiceError.message("Twitch Client IDが未設定です")))
      return
    }
    var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/device")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Self.formBody([
      "client_id": config.clientId,
      "scopes": "user:read:chat user:write:chat"
    ])
    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      guard let data,
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let deviceCode = json["device_code"] as? String,
            let userCode = json["user_code"] as? String,
            let verification = json["verification_uri"] as? String,
            let verificationURL = URL(string: verification) else {
        Self.finish(completion, .failure(OAuthServiceError.message("Twitch Device Codeを取得できません")))
        return
      }
      let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 1800
      let interval = (json["interval"] as? NSNumber)?.doubleValue ?? 5
      DispatchQueue.main.async {
        self.presentDeviceAuthorization(
          anchor: presentationAnchor,
          deviceCode: deviceCode,
          userCode: userCode,
          verificationURL: verificationURL,
          expiresAt: Date().timeIntervalSince1970 + expiresIn,
          interval: max(3, interval),
          completion: completion
        )
      }
    }.resume()
  }

  private func presentDeviceAuthorization(
    anchor: ASPresentationAnchor,
    deviceCode: String,
    userCode: String,
    verificationURL: URL,
    expiresAt: TimeInterval,
    interval: TimeInterval,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    devicePollWorkItem?.cancel()
    activeDeviceCode = deviceCode
    UIPasteboard.general.string = userCode
    let alert = UIAlertController(
      title: "Twitch認証コード: \(userCode)",
      message: "認証コードをコピーしました。ブラウザで貼り付けてTwitch連携を許可してください。完了後は自動で反映されます。",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "ブラウザを開く", style: .default) { _ in
      UIPasteboard.general.string = userCode
      UIApplication.shared.open(verificationURL)
    })
    alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { [weak self] _ in
      guard let self, self.activeDeviceCode == deviceCode else { return }
      self.devicePollWorkItem?.cancel()
      self.devicePollWorkItem = nil
      self.activeDeviceCode = nil
      Self.finish(completion, .failure(OAuthServiceError.message("Twitch認証をキャンセルしました")))
    })
    deviceAuthAlert = alert
    var presenter = anchor.rootViewController
    while let presented = presenter?.presentedViewController {
      presenter = presented
    }
    presenter?.present(alert, animated: true)
    scheduleDevicePoll(
      deviceCode: deviceCode,
      expiresAt: expiresAt,
      interval: interval,
      completion: completion
    )
  }

  private func scheduleDevicePoll(
    deviceCode: String,
    expiresAt: TimeInterval,
    interval: TimeInterval,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.scheduleDevicePoll(
          deviceCode: deviceCode,
          expiresAt: expiresAt,
          interval: interval,
          completion: completion
        )
      }
      return
    }
    guard activeDeviceCode == deviceCode else { return }
    guard Date().timeIntervalSince1970 < expiresAt else {
      finishDeviceAuthorization(
        deviceCode: deviceCode,
        completion: completion,
        result: .failure(OAuthServiceError.message("Twitch認証コードの期限が切れました"))
      )
      return
    }
    let work = DispatchWorkItem { [weak self] in
      self?.pollDeviceToken(
        deviceCode: deviceCode,
        expiresAt: expiresAt,
        interval: interval,
        completion: completion
      )
    }
    devicePollWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + max(3, interval), execute: work)
  }

  private func pollDeviceToken(
    deviceCode: String,
    expiresAt: TimeInterval,
    interval: TimeInterval,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard activeDeviceCode == deviceCode else { return }
    var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Self.formBody([
      "client_id": config.clientId,
      "scopes": "user:read:chat user:write:chat",
      "device_code": deviceCode,
      "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
    ])
    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self, self.activeDeviceCode == deviceCode else { return }
      if let error {
        self.scheduleDevicePoll(
          deviceCode: deviceCode,
          expiresAt: expiresAt,
          interval: min(60, max(interval, interval * 2)),
          completion: completion
        )
        _ = error
        return
      }
      let http = response as? HTTPURLResponse
      let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
      if let accessToken = json["access_token"] as? String,
         let refreshToken = json["refresh_token"] as? String,
         let status = http?.statusCode,
         (200..<300).contains(status) {
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 14_400
        let token = SimpleOAuthToken(
          accessToken: accessToken,
          expiresAt: Date().timeIntervalSince1970 + max(60, expiresIn - 60),
          userID: nil,
          refreshToken: refreshToken
        )
        OAuthKeychain.save(token, account: self.tokenAccount)
        self.validate(accessToken: accessToken) { result in
          if case .success(let userID) = result {
            OAuthKeychain.save(SimpleOAuthToken(
              accessToken: token.accessToken,
              expiresAt: token.expiresAt,
              userID: userID,
              refreshToken: token.refreshToken
            ), account: self.tokenAccount)
          }
        }
        self.finishDeviceAuthorization(deviceCode: deviceCode, completion: completion, result: .success(()))
        return
      }
      let message = ((json["message"] as? String) ?? (json["error"] as? String) ?? "").lowercased()
      if message.contains("authorization_pending") {
        self.scheduleDevicePoll(deviceCode: deviceCode, expiresAt: expiresAt, interval: interval, completion: completion)
      } else if message.contains("slow_down") {
        self.scheduleDevicePoll(deviceCode: deviceCode, expiresAt: expiresAt, interval: interval + 5, completion: completion)
      } else if http?.statusCode == 429 || (http?.statusCode ?? 0) >= 500 {
        self.scheduleDevicePoll(deviceCode: deviceCode, expiresAt: expiresAt, interval: min(60, interval * 2), completion: completion)
      } else {
        self.finishDeviceAuthorization(
          deviceCode: deviceCode,
          completion: completion,
          result: .failure(OAuthServiceError.message(message.isEmpty ? "Twitch token取得に失敗しました" : message))
        )
      }
    }.resume()
  }

  private func finishDeviceAuthorization(
    deviceCode: String,
    completion: @escaping (Result<Void, Error>) -> Void,
    result: Result<Void, Error>
  ) {
    DispatchQueue.main.async {
      guard self.activeDeviceCode == deviceCode else { return }
      self.devicePollWorkItem?.cancel()
      self.devicePollWorkItem = nil
      self.activeDeviceCode = nil
      self.deviceAuthAlert?.dismiss(animated: true)
      Self.finish(completion, result)
    }
  }

  func maintainSession() {
    guard let token = OAuthKeychain.load(account: tokenAccount),
          token.expiresAt - Date().timeIntervalSince1970 <= 300 else { return }
    withValidToken(minimumValidity: 300) { _ in }
  }

  func sendChat(channel: String, content: String, completion: @escaping (Result<Void, Error>) -> Void) {
    withValidToken { result in
      switch result {
      case .failure(let error):
        Self.finish(completion, .failure(error))
      case .success(let token):
        guard let senderID = token.userID else {
          Self.finish(completion, .failure(OAuthServiceError.message("TwitchユーザーIDを取得できません")))
          return
        }
        self.resolveUserID(login: channel, accessToken: token.accessToken) { result in
          switch result {
          case .failure(let error):
            Self.finish(completion, .failure(error))
          case .success(let broadcasterID):
            self.postMessage(broadcasterID: broadcasterID, senderID: senderID, message: content, accessToken: token.accessToken, completion: completion)
          }
        }
      }
    }
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    authAnchor ?? ASPresentationAnchor()
  }

  private func withValidToken(
    minimumValidity: TimeInterval = 60,
    completion: @escaping (Result<SimpleOAuthToken, Error>) -> Void
  ) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.withValidToken(minimumValidity: minimumValidity, completion: completion)
      }
      return
    }
    guard let token = OAuthKeychain.load(account: tokenAccount) else {
      Self.finish(completion, .failure(OAuthServiceError.message("Twitchにログインしてください")))
      return
    }
    let remaining = token.expiresAt - Date().timeIntervalSince1970
    if remaining > minimumValidity || (remaining > 0 && token.refreshToken?.isEmpty != false) {
      ensureUserID(token: token, completion: completion)
      return
    }
    guard token.refreshToken?.isEmpty == false else {
      Self.finish(completion, .failure(OAuthServiceError.message("Twitchログインの期限が切れました。設定から一度だけ再ログインしてください（以降は自動更新されます）")))
      return
    }
    refreshAccessToken(previous: token) { result in
      switch result {
      case .failure(let error):
        Self.finish(completion, .failure(error))
      case .success(let refreshed):
        self.ensureUserID(token: refreshed, completion: completion)
      }
    }
  }

  private func ensureUserID(
    token: SimpleOAuthToken,
    completion: @escaping (Result<SimpleOAuthToken, Error>) -> Void
  ) {
    if token.userID?.isEmpty == false {
      Self.finish(completion, .success(token))
      return
    }
    validate(accessToken: token.accessToken) { result in
      switch result {
      case .failure(let error):
        Self.finish(completion, .failure(error))
      case .success(let userID):
        let updated = SimpleOAuthToken(
          accessToken: token.accessToken,
          expiresAt: token.expiresAt,
          userID: userID,
          refreshToken: token.refreshToken
        )
        OAuthKeychain.save(updated, account: self.tokenAccount)
        Self.finish(completion, .success(updated))
      }
    }
  }

  private func refreshAccessToken(
    previous: SimpleOAuthToken,
    completion: @escaping (Result<SimpleOAuthToken, Error>) -> Void
  ) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.refreshAccessToken(previous: previous, completion: completion)
      }
      return
    }
    refreshWaiters.append(completion)
    guard !refreshInFlight else { return }
    refreshInFlight = true
    var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Self.formBody([
      "client_id": config.clientId,
      "grant_type": "refresh_token",
      "refresh_token": previous.refreshToken ?? ""
    ])
    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      let result: Result<SimpleOAuthToken, Error>
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      if let error {
        result = .failure(error)
      } else if let data,
                (200..<300).contains(status),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let accessToken = json["access_token"] as? String,
                let refreshToken = json["refresh_token"] as? String {
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 14_400
        result = .success(SimpleOAuthToken(
          accessToken: accessToken,
          expiresAt: Date().timeIntervalSince1970 + max(60, expiresIn - 60),
          userID: previous.userID,
          refreshToken: refreshToken
        ))
      } else {
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let message = (json?["message"] as? String) ?? (json?["error_description"] as? String) ?? "Twitchトークン更新に失敗しました"
        result = .failure(OAuthServiceError.message(message))
      }
      DispatchQueue.main.async {
        if case .success(let token) = result {
          OAuthKeychain.save(token, account: self.tokenAccount)
        } else if status == 400 || status == 401 {
          OAuthKeychain.save(nil, account: self.tokenAccount)
        }
        self.refreshInFlight = false
        let waiters = self.refreshWaiters
        self.refreshWaiters.removeAll()
        waiters.forEach { Self.finish($0, result) }
      }
    }.resume()
  }

  private func validate(accessToken: String, completion: @escaping (Result<String, Error>) -> Void) {
    var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
    request.setValue("OAuth \(accessToken)", forHTTPHeaderField: "Authorization")
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      guard let data,
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let userID = json["user_id"] as? String else {
        Self.finish(completion, .failure(OAuthServiceError.message("TwitchユーザーIDを取得できません")))
        return
      }
      Self.finish(completion, .success(userID))
    }.resume()
  }

  private func resolveUserID(login rawLogin: String, accessToken: String, completion: @escaping (Result<String, Error>) -> Void) {
    let login = rawLogin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .replacingOccurrences(of: "^@+", with: "", options: .regularExpression)
      .components(separatedBy: CharacterSet(charactersIn: "/?# ")).first ?? rawLogin
    var components = URLComponents(string: "https://api.twitch.tv/helix/users")!
    components.queryItems = [URLQueryItem(name: "login", value: login)]
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(config.clientId, forHTTPHeaderField: "Client-Id")
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      guard let data,
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = json["data"] as? [[String: Any]],
            let id = rows.first?["id"] as? String else {
        Self.finish(completion, .failure(OAuthServiceError.message("TwitchチャンネルIDを取得できません")))
        return
      }
      Self.finish(completion, .success(id))
    }.resume()
  }

  private func postMessage(broadcasterID: String, senderID: String, message: String, accessToken: String, completion: @escaping (Result<Void, Error>) -> Void) {
    var request = URLRequest(url: URL(string: "https://api.twitch.tv/helix/chat/messages")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(config.clientId, forHTTPHeaderField: "Client-Id")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "broadcaster_id": broadcasterID,
      "sender_id": senderID,
      "message": message
    ])
    URLSession.shared.dataTask(with: request) { _, response, error in
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        Self.finish(completion, .failure(OAuthServiceError.message("Twitchコメント送信に失敗しました")))
        return
      }
      Self.finish(completion, .success(()))
    }.resume()
  }

  private static func fragmentValues(_ url: URL) -> [String: String]? {
    guard let fragment = url.fragment else { return nil }
    var output: [String: String] = [:]
    URLComponents(string: "x://callback?\(fragment)")?.queryItems?.forEach { output[$0.name] = $0.value }
    return output
  }

  private static func formBody(_ values: [String: String]) -> Data {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return values.map { key, value in
      let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
      let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
      return "\(encodedKey)=\(encodedValue)"
    }.joined(separator: "&").data(using: .utf8) ?? Data()
  }

  private static func finish<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ result: Result<T, Error>) {
    DispatchQueue.main.async { completion(result) }
  }
}

struct TwitcastingOAuthConfig: Codable {
  var clientId = ""
  var redirectURI = "multiview://twitcasting-oauth"
}

final class TwitcastingAuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {
  static let shared = TwitcastingAuthManager()
  private let configKey = "twitcasting.oauth.config.v1"
  private let tokenAccount = "twitcasting"
  private var activeSession: ASWebAuthenticationSession?
  private var authAnchor: ASPresentationAnchor?

  var config: TwitcastingOAuthConfig {
    get {
      guard let data = UserDefaults.standard.data(forKey: configKey),
            let config = try? JSONDecoder().decode(TwitcastingOAuthConfig.self, from: data) else {
        return TwitcastingOAuthConfig()
      }
      return config
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        UserDefaults.standard.set(data, forKey: configKey)
      }
    }
  }

  var isSignedIn: Bool { OAuthKeychain.load(account: tokenAccount)?.isValid == true }

  func signOut() {
    OAuthKeychain.save(nil, account: tokenAccount)
  }

  func signIn(presentationAnchor: ASPresentationAnchor?, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let presentationAnchor else {
      Self.finish(completion, .failure(OAuthServiceError.message("ツイキャス認証を開始できません")))
      return
    }
    let config = self.config
    guard !config.clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      Self.finish(completion, .failure(OAuthServiceError.message("ツイキャス Client IDが未設定です")))
      return
    }
    let state = UUID().uuidString
    var components = URLComponents(string: "https://apiv2.twitcasting.tv/oauth2/authorize")!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: config.clientId),
      URLQueryItem(name: "redirect_uri", value: config.redirectURI),
      URLQueryItem(name: "response_type", value: "token"),
      URLQueryItem(name: "state", value: state)
    ]
    guard let url = components.url else {
      Self.finish(completion, .failure(OAuthServiceError.message("ツイキャス認証URLを作成できません")))
      return
    }
    authAnchor = presentationAnchor
    let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "multiview") { [weak self] callbackURL, error in
      guard let self else { return }
      self.activeSession = nil
      self.authAnchor = nil
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      guard let callbackURL,
            let values = Self.fragmentValues(callbackURL),
            values["state"] == state,
            let accessToken = values["access_token"] else {
        Self.finish(completion, .failure(OAuthServiceError.message("ツイキャス認証の戻りURLが不正です")))
        return
      }
      // The provider documents 15,552,000 seconds (180 days) for implicit tokens.
      // TwitCasting does not issue refresh tokens to this public mobile flow.
      let expiresIn = Double(values["expires_in"] ?? "") ?? 15_552_000
      OAuthKeychain.save(SimpleOAuthToken(
        accessToken: accessToken,
        expiresAt: Date().timeIntervalSince1970 + max(60, expiresIn - 60),
        userID: nil
      ), account: tokenAccount)
      Self.finish(completion, .success(()))
    }
    session.presentationContextProvider = self
    session.prefersEphemeralWebBrowserSession = false
    activeSession = session
    if !session.start() {
      activeSession = nil
      authAnchor = nil
      Self.finish(completion, .failure(OAuthServiceError.message("ツイキャス認証を開始できません")))
    }
  }

  func sendChat(channel: String, content: String, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let token = OAuthKeychain.load(account: tokenAccount), token.isValid else {
      Self.finish(completion, .failure(OAuthServiceError.message("ツイキャスにログインしてください")))
      return
    }
    resolveMovieID(channel: channel) { result in
      switch result {
      case .failure(let error):
        Self.finish(completion, .failure(error))
      case .success(let movieID):
        self.postComment(movieID: movieID, content: content, accessToken: token.accessToken, completion: completion)
      }
    }
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    authAnchor ?? ASPresentationAnchor()
  }

  private func resolveMovieID(channel: String, completion: @escaping (Result<String, Error>) -> Void) {
    let user = channel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let encoded = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          let url = URL(string: "https://frontendapi.twitcasting.tv/users/\(encoded)/latest-movie") else {
      Self.finish(completion, .failure(OAuthServiceError.message("ツイキャスユーザーIDが不正です")))
      return
    }
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(BrowserUserAgent.mobileWebKit, forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: request) { data, _, error in
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      guard let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let movie = json["movie"] as? [String: Any],
            let id = Self.stringValue(movie["id"]) else {
        Self.finish(completion, .failure(OAuthServiceError.message("ツイキャス配信IDを取得できません")))
        return
      }
      Self.finish(completion, .success(id))
    }.resume()
  }

  private func postComment(movieID: String, content: String, accessToken: String, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let url = URL(string: "https://apiv2.twitcasting.tv/movies/\(movieID)/comments") else {
      Self.finish(completion, .failure(OAuthServiceError.message("ツイキャス配信IDが不正です")))
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("2.0", forHTTPHeaderField: "X-Api-Version")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["comment": String(content.prefix(140)), "sns": "none"])
    URLSession.shared.dataTask(with: request) { _, response, error in
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        Self.finish(completion, .failure(OAuthServiceError.message("ツイキャスコメント送信に失敗しました")))
        return
      }
      Self.finish(completion, .success(()))
    }.resume()
  }

  private static func fragmentValues(_ url: URL) -> [String: String]? {
    guard let fragment = url.fragment else { return nil }
    var output: [String: String] = [:]
    URLComponents(string: "x://callback?\(fragment)")?.queryItems?.forEach { output[$0.name] = $0.value }
    return output
  }

  private static func stringValue(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
  }

  private static func finish<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ result: Result<T, Error>) {
    DispatchQueue.main.async { completion(result) }
  }
}

struct YouTubeOAuthConfig: Codable {
  var clientId = ""
  var redirectURI = ""
}

struct YouTubeLiveChatMessage {
  let id: String
  let author: String
  let text: String
  let tokens: [NativeDanmakuToken]
  // Super Chat / Super Sticker / メンバー加入 のとき金額や種別の表示文字列。通常チャットは nil。
  let superInfo: String?

  init(id: String, author: String, text: String, superInfo: String?, tokens: [NativeDanmakuToken]? = nil) {
    self.id = id
    self.author = author
    self.text = text
    self.superInfo = superInfo
    self.tokens = tokens ?? NativeDanmakuRenderer.textTokens(text)
  }
}

struct YouTubeLiveChatPage {
  let messages: [YouTubeLiveChatMessage]
  let nextPageToken: String?
  let pollingIntervalMillis: Int
}

final class YouTubeAuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {
  static let shared = YouTubeAuthManager()
  private let configKey = "youtube.oauth.config.v1"
  private let tokenAccount = "youtube"
  private var activeSession: ASWebAuthenticationSession?
  private var authAnchor: ASPresentationAnchor?

  var config: YouTubeOAuthConfig {
    get {
      guard let data = UserDefaults.standard.data(forKey: configKey),
            let config = try? JSONDecoder().decode(YouTubeOAuthConfig.self, from: data) else {
        return YouTubeOAuthConfig()
      }
      return config
    }
    set {
      if let data = try? JSONEncoder().encode(newValue) {
        UserDefaults.standard.set(data, forKey: configKey)
      }
    }
  }

  var isSignedIn: Bool {
    guard let token = OAuthKeychain.load(account: tokenAccount) else { return false }
    return token.isValid || token.refreshToken?.isEmpty == false
  }

  func signOut() {
    OAuthKeychain.save(nil, account: tokenAccount)
  }

  func maintainSession() {
    guard let token = OAuthKeychain.load(account: tokenAccount),
          token.refreshToken?.isEmpty == false,
          token.expiresAt - Date().timeIntervalSince1970 <= 300 else { return }
    withValidAccessToken(minimumValidity: 300) { _ in }
  }

  func signIn(presentationAnchor: ASPresentationAnchor?, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let presentationAnchor else {
      Self.finish(completion, .failure(OAuthServiceError.message("YouTube認証を開始できません")))
      return
    }
    let config = self.config
    guard !config.clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      Self.finish(completion, .failure(OAuthServiceError.message("YouTube Client IDが未設定です")))
      return
    }
    let redirectURI = Self.effectiveRedirectURI(for: config)
    guard let callbackScheme = URLComponents(string: redirectURI)?.scheme, !callbackScheme.isEmpty else {
      Self.finish(completion, .failure(OAuthServiceError.message("YouTube Redirect URIを作成できません。iOS OAuth Client IDを確認してください。")))
      return
    }
    let verifier = Self.randomVerifier()
    let state = UUID().uuidString
    var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: config.clientId),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/youtube.force-ssl"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "prompt", value: "consent"),
      URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
      URLQueryItem(name: "code_challenge_method", value: "S256")
    ]
    guard let url = components.url else {
      Self.finish(completion, .failure(OAuthServiceError.message("YouTube認証URLを作成できません")))
      return
    }
    authAnchor = presentationAnchor
    let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
      guard let self else { return }
      self.activeSession = nil
      self.authAnchor = nil
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      guard let callbackURL,
            let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            callback.queryItems?.first(where: { $0.name == "state" })?.value == state,
            let code = callback.queryItems?.first(where: { $0.name == "code" })?.value else {
        Self.finish(completion, .failure(OAuthServiceError.message("YouTube認証の戻りURLが不正です")))
        return
      }
      self.exchangeCode(code, verifier: verifier, redirectURI: redirectURI, completion: completion)
    }
    session.presentationContextProvider = self
    session.prefersEphemeralWebBrowserSession = false
    activeSession = session
    if !session.start() {
      activeSession = nil
      authAnchor = nil
      Self.finish(completion, .failure(OAuthServiceError.message("YouTube認証を開始できません")))
    }
  }

  func sendChat(channel: String, content: String, completion: @escaping (Result<Void, Error>) -> Void) {
    withValidAccessToken { result in
      switch result {
      case .failure(let error):
        Self.finish(completion, .failure(error))
      case .success(let accessToken):
        self.resolveVideoID(from: channel) { result in
          switch result {
          case .failure(let error):
            Self.finish(completion, .failure(error))
          case .success(let videoID):
            self.resolveLiveChatID(videoID: videoID, accessToken: accessToken) { chatResult in
              switch chatResult {
              case .failure(let error):
                Self.finish(completion, .failure(error))
              case .success(let liveChatID):
                self.postMessage(liveChatID: liveChatID, message: content, accessToken: accessToken, completion: completion)
              }
            }
          }
        }
      }
    }
  }

  func resolveLiveChat(videoID: String, completion: @escaping (Result<(liveChatID: String, accessToken: String), Error>) -> Void) {
    withValidAccessToken { result in
      switch result {
      case .failure(let error):
        Self.finish(completion, .failure(error))
      case .success(let accessToken):
        self.resolveLiveChatID(videoID: videoID, accessToken: accessToken) { result in
          switch result {
          case .failure(let error):
            Self.finish(completion, .failure(error))
          case .success(let liveChatID):
            Self.finish(completion, .success((liveChatID, accessToken)))
          }
        }
      }
    }
  }

  // Returns a usable access token, transparently refreshing via the stored refresh
  // token when the current one has expired. YouTube access tokens last ~1h, which is
  // why the danmaku used to stop (and only a manual re-login fixed it).
  private func withValidAccessToken(
    minimumValidity: TimeInterval = 60,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    guard let token = OAuthKeychain.load(account: tokenAccount) else {
      Self.finish(completion, .failure(OAuthServiceError.message("YouTubeチャット弾幕: YouTubeにログインしてください")))
      return
    }
    if token.expiresAt - Date().timeIntervalSince1970 > minimumValidity
      || (token.isValid && token.refreshToken?.isEmpty != false) {
      Self.finish(completion, .success(token.accessToken))
      return
    }
    guard let refreshToken = token.refreshToken else {
      Self.finish(completion, .failure(OAuthServiceError.message("YouTubeログインの期限が切れました。設定から一度だけ再ログインしてください（以降は自動更新されます）")))
      return
    }
    refreshAccessToken(refreshToken) { result in
      switch result {
      case .success(let newToken):
        OAuthKeychain.save(newToken, account: self.tokenAccount)
        Self.finish(completion, .success(newToken.accessToken))
      case .failure(let error):
        Self.finish(completion, .failure(error))
      }
    }
  }

  private func refreshAccessToken(_ refreshToken: String, completion: @escaping (Result<SimpleOAuthToken, Error>) -> Void) {
    var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Self.formBody([
      "client_id": config.clientId,
      "grant_type": "refresh_token",
      "refresh_token": refreshToken
    ])
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      guard let data,
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = json["access_token"] as? String else {
        Self.finish(completion, .failure(OAuthServiceError.message("YouTubeトークン更新に失敗しました。設定から再ログインしてください")))
        return
      }
      let expiresIn = json["expires_in"] as? Double ?? 3600
      // A refresh response usually omits refresh_token; keep the existing one.
      let newRefresh = (json["refresh_token"] as? String) ?? refreshToken
      Self.finish(completion, .success(SimpleOAuthToken(
        accessToken: accessToken,
        expiresAt: Date().timeIntervalSince1970 + max(60, expiresIn - 60),
        userID: nil,
        refreshToken: newRefresh
      )))
    }.resume()
  }

  func fetchLiveChatMessages(
    liveChatID: String,
    pageToken: String?,
    accessToken: String,
    completion: @escaping (Result<YouTubeLiveChatPage, Error>) -> Void
  ) {
    var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/liveChat/messages")!
    var items = [
      URLQueryItem(name: "liveChatId", value: liveChatID),
      URLQueryItem(name: "part", value: "snippet,authorDetails"),
      URLQueryItem(name: "maxResults", value: "200"),
      URLQueryItem(name: "profileImageSize", value: "16")
    ]
    if let pageToken, !pageToken.isEmpty {
      items.append(URLQueryItem(name: "pageToken", value: pageToken))
    }
    components.queryItems = items
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      guard let data,
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.finish(completion, .failure(OAuthServiceError.message(detail.isEmpty ? "YouTubeチャット取得失敗 (HTTP \(status))" : "YouTubeチャット取得失敗 (HTTP \(status)): \(detail)")))
        return
      }
      let parsedItems = json["items"] as? [[String: Any]] ?? []
      let messages = parsedItems.compactMap { item -> YouTubeLiveChatMessage? in
        guard let id = item["id"] as? String,
              let snippet = item["snippet"] as? [String: Any] else { return nil }
        let type = (snippet["type"] as? String) ?? ""
        let author = ((item["authorDetails"] as? [String: Any])?["displayName"] as? String) ?? ""
        let text = (snippet["displayMessage"] as? String)
          ?? ((snippet["textMessageDetails"] as? [String: Any])?["messageText"] as? String)
          ?? ""
        // Super Chat / Super Sticker / メンバー加入 は投げ銭系イベントとして拾う(同じ liveChat 応答に含まれる)。
        if type == "superChatEvent" || type == "superStickerEvent" {
          let details = (snippet["superChatDetails"] ?? snippet["superStickerDetails"]) as? [String: Any]
          let amount = (details?["amountDisplayString"] as? String) ?? "Super Chat"
          let comment = (details?["userComment"] as? String) ?? text
          return YouTubeLiveChatMessage(id: id, author: author, text: comment, superInfo: amount)
        }
        if type == "newSponsorEvent" || type == "memberMilestoneChatEvent" {
          return YouTubeLiveChatMessage(id: id, author: author, text: text, superInfo: "メンバー加入")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return YouTubeLiveChatMessage(id: id, author: author, text: text, superInfo: nil)
      }
      let page = YouTubeLiveChatPage(
        messages: messages,
        nextPageToken: json["nextPageToken"] as? String,
        pollingIntervalMillis: (json["pollingIntervalMillis"] as? Int) ?? 5000
      )
      Self.finish(completion, .success(page))
    }.resume()
  }

  // 固定 token を使い続けると ~1時間で 401 になり弾幕/Super Chat が止まる。毎回
  // withValidAccessToken で有効 token を取得(期限切れは自動リフレッシュ)してから取得する版。
  func fetchLiveChatMessagesRefreshing(
    liveChatID: String,
    pageToken: String?,
    completion: @escaping (Result<YouTubeLiveChatPage, Error>) -> Void
  ) {
    withValidAccessToken { [weak self] result in
      switch result {
      case .failure(let error):
        Self.finish(completion, .failure(error))
      case .success(let accessToken):
        self?.fetchLiveChatMessages(liveChatID: liveChatID, pageToken: pageToken, accessToken: accessToken, completion: completion)
      }
    }
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    authAnchor ?? ASPresentationAnchor()
  }

  private static func reversedIOSClientID(from clientID: String) -> String? {
    let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    let suffix = ".apps.googleusercontent.com"
    guard trimmed.hasSuffix(suffix), trimmed.count > suffix.count else { return nil }
    let id = String(trimmed.dropLast(suffix.count))
    return "com.googleusercontent.apps.\(id)"
  }

  static func effectiveRedirectURI(for config: YouTubeOAuthConfig) -> String {
    let raw = config.redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
    if !raw.isEmpty, !raw.hasPrefix("multiview://") {
      return raw
    }
    if let scheme = reversedIOSClientID(from: config.clientId) {
      return "\(scheme):/oauth2redirect/google"
    }
    return raw
  }

  static func defaultRedirectURI(forClientID clientID: String) -> String? {
    reversedIOSClientID(from: clientID).map { "\($0):/oauth2redirect/google" }
  }

  private func exchangeCode(_ code: String, verifier: String, redirectURI: String, completion: @escaping (Result<Void, Error>) -> Void) {
    var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let body = [
      "client_id": config.clientId,
      "redirect_uri": redirectURI,
      "grant_type": "authorization_code",
      "code": code,
      "code_verifier": verifier
    ]
    request.httpBody = Self.formBody(body)
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      guard let data,
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = json["access_token"] as? String else {
        Self.finish(completion, .failure(OAuthServiceError.message("YouTube OAuthトークン取得に失敗しました")))
        return
      }
      let expiresIn = json["expires_in"] as? Double ?? 3600
      let existingRefreshToken = OAuthKeychain.load(account: self.tokenAccount)?.refreshToken
      OAuthKeychain.save(SimpleOAuthToken(
        accessToken: accessToken,
        expiresAt: Date().timeIntervalSince1970 + max(60, expiresIn - 60),
        userID: nil,
        refreshToken: (json["refresh_token"] as? String) ?? existingRefreshToken
      ), account: self.tokenAccount)
      Self.finish(completion, .success(()))
    }.resume()
  }

  private func resolveVideoID(from raw: String, completion: @escaping (Result<String, Error>) -> Void) {
    if let videoID = YouTubeNativePlayerView.videoID(from: raw) {
      Self.finish(completion, .success(videoID))
      return
    }
    guard let url = YouTubeNativePlayerView.liveResolutionURL(from: raw) else {
      Self.finish(completion, .failure(OAuthServiceError.message("YouTube動画IDまたはライブURLが不正です")))
      return
    }
    var request = URLRequest(url: url)
    request.setValue(YouTubeNativePlayerView.userAgent, forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      if let finalURL = response?.url, let id = YouTubeNativePlayerView.videoID(from: finalURL.absoluteString) {
        Self.finish(completion, .success(id))
        return
      }
      guard let data,
            let html = String(data: data, encoding: .utf8),
            let id = YouTubeNativePlayerView.extractVideoID(fromHTML: html) else {
        Self.finish(completion, .failure(OAuthServiceError.message("YouTubeライブ動画IDを取得できません")))
        return
      }
      Self.finish(completion, .success(id))
    }.resume()
  }

  private func resolveLiveChatID(videoID: String, accessToken: String, completion: @escaping (Result<String, Error>) -> Void) {
    var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
    components.queryItems = [
      URLQueryItem(name: "part", value: "liveStreamingDetails"),
      URLQueryItem(name: "id", value: videoID)
    ]
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      guard let data,
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = json["items"] as? [[String: Any]],
            let details = items.first?["liveStreamingDetails"] as? [String: Any],
            let liveChatID = details["activeLiveChatId"] as? String else {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.finish(completion, .failure(OAuthServiceError.message(detail.isEmpty ? "YouTubeライブチャットIDを取得できません (HTTP \(status))" : "YouTubeライブチャットIDを取得できません (HTTP \(status)): \(detail)")))
        return
      }
      Self.finish(completion, .success(liveChatID))
    }.resume()
  }

  private func postMessage(liveChatID: String, message: String, accessToken: String, completion: @escaping (Result<Void, Error>) -> Void) {
    var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/liveChat/messages")!
    components.queryItems = [URLQueryItem(name: "part", value: "snippet")]
    var request = URLRequest(url: components.url!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "snippet": [
        "liveChatId": liveChatID,
        "type": "textMessageEvent",
        "textMessageDetails": ["messageText": message]
      ]
    ])
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if status == 404 {
          Self.finish(completion, .failure(OAuthServiceError.message("YouTubeライブチャットが見つかりません。配信が終了した、チャットが無効、またはliveChatIdが古い可能性があります。")))
        } else {
          let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
          Self.finish(completion, .failure(OAuthServiceError.message(detail.isEmpty ? "YouTubeコメント送信に失敗しました (HTTP \(status))" : "YouTubeコメント送信に失敗しました (HTTP \(status)): \(detail)")))
        }
        return
      }
      Self.finish(completion, .success(()))
    }.resume()
  }

  private static func randomVerifier() -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    return String((0..<64).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
  }

  private static func codeChallenge(for verifier: String) -> String {
    Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func formBody(_ values: [String: String]) -> Data {
    values
      .map { key, value in
        "\(escape(key))=\(escape(value))"
      }
      .joined(separator: "&")
      .data(using: .utf8) ?? Data()
  }

  private static func escape(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private static func finish<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ result: Result<T, Error>) {
    DispatchQueue.main.async { completion(result) }
  }
}

enum OAuthServiceError: LocalizedError {
  case message(String)

  var errorDescription: String? {
    switch self {
    case .message(let text): return text
    }
  }
}
