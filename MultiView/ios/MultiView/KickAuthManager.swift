import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

struct KickOAuthConfig: Codable {
  var clientId = ""
  var clientSecret = ""
  // Kick only accepts an https redirect URI, so we register this hosted bridge page
  // which forwards to the app's custom scheme (captured by ASWebAuthenticationSession).
  var redirectURI = "https://tonton888115.github.io/MultiView/kick-oauth.html"

  init() {}

  private enum CodingKeys: String, CodingKey {
    case clientId
    case clientSecret
    case redirectURI
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    clientId = try container.decodeIfPresent(String.self, forKey: .clientId) ?? ""
    clientSecret = try container.decodeIfPresent(String.self, forKey: .clientSecret) ?? ""
    redirectURI = try container.decodeIfPresent(String.self, forKey: .redirectURI) ?? KickOAuthConfig().redirectURI
  }
}

struct KickOAuthToken: Codable {
  let accessToken: String
  let refreshToken: String?
  let expiresAt: TimeInterval
  let scope: String?

  var isValid: Bool {
    Date().timeIntervalSince1970 < expiresAt
  }
}

final class KickAuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {
  static let shared = KickAuthManager()

  private let configKey = "kick.oauth.config.v1"
  private let channelCacheKey = "kick.channel.cache.v1"
  private let keychainService = "com.rinng.multiview.kick"
  private let keychainAccount = "oauth-token"
  private var activeSession: ASWebAuthenticationSession?
  private var authAnchor: ASPresentationAnchor?

  // Custom-scheme redirect URIs the Kick portal rejects; migrate them to the hosted
  // https bridge so existing installs work without the user re-entering anything.
  private let callbackScheme = "multiview"

  // id.kick.com / api.kick.com sit behind Cloudflare, which returns a 400 "challenge"
  // page to requests that don't look like a browser (the default URLSession UA gets
  // blocked). Sending a full browser-like header set lets the API calls through.
  private static let browserUserAgent = BrowserUserAgent.mobileSafari

  private static func applyBrowserHeaders(_ request: inout URLRequest) {
    request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    request.setValue("ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
    request.setValue("https://kick.com", forHTTPHeaderField: "Origin")
    request.setValue("https://kick.com/", forHTTPHeaderField: "Referer")
  }

  var config: KickOAuthConfig {
    get {
      guard let data = UserDefaults.standard.data(forKey: configKey),
            var config = try? JSONDecoder().decode(KickOAuthConfig.self, from: data) else {
        return KickOAuthConfig()
      }
      if config.redirectURI.isEmpty || config.redirectURI.hasPrefix("multiview://") {
        config.redirectURI = KickOAuthConfig().redirectURI
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
    loadToken() != nil
  }

  func signOut() {
    saveToken(nil)
  }

  func signIn(presentationAnchor: ASPresentationAnchor?, completion: @escaping (Result<Void, Error>) -> Void) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.signIn(presentationAnchor: presentationAnchor, completion: completion)
      }
      return
    }
    guard let presentationAnchor else {
      Self.finish(completion, .failure(KickAuthError.couldNotStartSession))
      return
    }
    let config = self.config
    guard !config.clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      Self.finish(completion, .failure(KickAuthError.missingClientId))
      return
    }
    // client_secret is optional: Kick "public" OAuth apps use pure PKCE (no secret),
    // while "confidential" apps require it. Requiring it unconditionally blocked
    // public-client users, so we only send it when the user actually provides one.
    guard URL(string: config.redirectURI) != nil else {
      Self.finish(completion, .failure(KickAuthError.invalidRedirectURI))
      return
    }
    // The redirect URI sent to Kick is the hosted https bridge, but the session
    // captures the app's custom scheme that the bridge forwards to.
    let callbackScheme = self.callbackScheme

    let verifier = Self.randomVerifier()
    let state = UUID().uuidString
    var components = URLComponents(string: "https://id.kick.com/oauth/authorize")
    components?.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: config.clientId),
      URLQueryItem(name: "redirect_uri", value: config.redirectURI),
      URLQueryItem(name: "scope", value: "user:read channel:read chat:write"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
      URLQueryItem(name: "code_challenge_method", value: "S256")
    ]
    guard let authURL = components?.url else {
      Self.finish(completion, .failure(KickAuthError.invalidAuthorizeURL))
      return
    }

    authAnchor = presentationAnchor
    let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
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
        Self.finish(completion, .failure(KickAuthError.invalidCallback))
        return
      }
      self.exchangeCode(code, verifier: verifier, completion: completion)
    }
    session.presentationContextProvider = self
    session.prefersEphemeralWebBrowserSession = false
    activeSession = session
    if !session.start() {
      activeSession = nil
      authAnchor = nil
      Self.finish(completion, .failure(KickAuthError.couldNotStartSession))
    }
  }

  func sendChat(channel: String, content: String, completion: @escaping (Result<Void, Error>) -> Void) {
    authorizedAccessToken { [weak self] tokenResult in
      guard let self else { return }
      switch tokenResult {
      case .failure(let error):
        Self.finish(completion, .failure(error))
      case .success(let accessToken):
        self.resolveBroadcasterID(channel: channel, accessToken: accessToken) { idResult in
          switch idResult {
          case .failure(let error):
            Self.finish(completion, .failure(error))
          case .success(let broadcasterID):
            self.postChat(broadcasterID: broadcasterID, content: content, accessToken: accessToken, completion: completion)
          }
        }
      }
    }
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    authAnchor ?? ASPresentationAnchor()
  }

  private func authorizedAccessToken(completion: @escaping (Result<String, Error>) -> Void) {
    guard let token = loadToken() else {
      Self.finish(completion, .failure(KickAuthError.notSignedIn))
      return
    }
    if token.isValid {
      Self.finish(completion, .success(token.accessToken))
      return
    }
    guard let refreshToken = token.refreshToken else {
      Self.finish(completion, .failure(KickAuthError.tokenExpired))
      return
    }
    refresh(refreshToken: refreshToken) { [weak self] result in
      switch result {
      case .failure(let error):
        self?.saveToken(nil)
        Self.finish(completion, .failure(error))
      case .success(let token):
        self?.saveToken(token)
        Self.finish(completion, .success(token.accessToken))
      }
    }
  }

  private func exchangeCode(_ code: String, verifier: String, completion: @escaping (Result<Void, Error>) -> Void) {
    let config = self.config
    var params: [String: String] = [
      "grant_type": "authorization_code",
      "client_id": config.clientId,
      "redirect_uri": config.redirectURI,
      "code": code,
      "code_verifier": verifier
    ]
    let secret = config.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    if !secret.isEmpty { params["client_secret"] = secret }
    let body = Self.formBody(params)
    tokenRequest(body: body) { [weak self] result in
      switch result {
      case .failure(let error):
        Self.finish(completion, .failure(error))
      case .success(let token):
        self?.saveToken(token)
        Self.finish(completion, .success(()))
      }
    }
  }

  private func refresh(refreshToken: String, completion: @escaping (Result<KickOAuthToken, Error>) -> Void) {
    var params: [String: String] = [
      "grant_type": "refresh_token",
      "client_id": config.clientId,
      "refresh_token": refreshToken
    ]
    let secret = config.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    if !secret.isEmpty { params["client_secret"] = secret }
    tokenRequest(body: Self.formBody(params), completion: completion)
  }

  private func tokenRequest(body: Data, completion: @escaping (Result<KickOAuthToken, Error>) -> Void) {
    var request = URLRequest(url: URL(string: "https://id.kick.com/oauth/token")!)
    request.httpMethod = "POST"
    Self.applyBrowserHeaders(&request)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      guard let data, let http = response as? HTTPURLResponse else {
        Self.finish(completion, .failure(KickAuthError.oauthRequestFailed("レスポンスを取得できませんでした")))
        return
      }
      guard (200..<300).contains(http.statusCode) else {
        Self.finish(completion, .failure(KickAuthError.oauthRequestFailed(Self.oauthErrorMessage(status: http.statusCode, data: data))))
        return
      }
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = json["access_token"] as? String else {
        Self.finish(completion, .failure(KickAuthError.oauthRequestFailed("トークンレスポンスを解析できませんでした")))
        return
      }
      let expiresIn = json["expires_in"] as? Double ?? 3600
      Self.finish(completion, .success(KickOAuthToken(
        accessToken: accessToken,
        refreshToken: json["refresh_token"] as? String,
        expiresAt: Date().timeIntervalSince1970 + max(60, expiresIn - 60),
        scope: json["scope"] as? String
      )))
    }.resume()
  }

  private func resolveBroadcasterID(channel: String, accessToken: String, completion: @escaping (Result<Int, Error>) -> Void) {
    let slug = channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var cache = UserDefaults.standard.dictionary(forKey: channelCacheKey) as? [String: Int] ?? [:]
    if let cached = cache[slug] {
      Self.finish(completion, .success(cached))
      return
    }
    var components = URLComponents(string: "https://api.kick.com/public/v1/channels")!
    components.queryItems = [URLQueryItem(name: "slug", value: slug)]
    guard let url = components.url else {
      Self.finish(completion, .failure(KickAuthError.invalidChannel))
      return
    }
    var request = URLRequest(url: url)
    Self.applyBrowserHeaders(&request)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      guard let data, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = json["data"] as? [[String: Any]],
            let rawID = rows.first?["broadcaster_user_id"] ?? rows.first?["user_id"],
            let id = Self.intValue(rawID) else {
        Self.finish(completion, .failure(KickAuthError.channelLookupFailed))
        return
      }
      cache[slug] = id
      UserDefaults.standard.set(cache, forKey: self.channelCacheKey)
      Self.finish(completion, .success(id))
    }.resume()
  }

  private func postChat(broadcasterID: Int, content: String, accessToken: String, completion: @escaping (Result<Void, Error>) -> Void) {
    var request = URLRequest(url: URL(string: "https://api.kick.com/public/v1/chat")!)
    request.httpMethod = "POST"
    Self.applyBrowserHeaders(&request)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "broadcaster_user_id": broadcasterID,
      "content": content,
      "type": "user"
    ])
    URLSession.shared.dataTask(with: request) { _, response, error in
      if let error {
        Self.finish(completion, .failure(error))
        return
      }
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        Self.finish(completion, .failure(KickAuthError.chatSendFailed))
        return
      }
      Self.finish(completion, .success(()))
    }.resume()
  }

  private func loadToken() -> KickOAuthToken? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else { return nil }
    return try? JSONDecoder().decode(KickOAuthToken.self, from: data)
  }

  private func saveToken(_ token: KickOAuthToken?) {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount
    ]
    SecItemDelete(base as CFDictionary)
    guard let token, let data = try? JSONEncoder().encode(token) else { return }
    var item = base
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(item as CFDictionary, nil)
  }

  private static func randomVerifier() -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    return String((0..<64).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
  }

  private static func codeChallenge(for verifier: String) -> String {
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return Data(digest).base64EncodedString()
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

  private static func finish<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ result: Result<T, Error>) {
    DispatchQueue.main.async {
      completion(result)
    }
  }

  private static func escape(_ value: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int {
      return value
    }
    if let value = value as? NSNumber {
      return value.intValue
    }
    if let value = value as? String {
      return Int(value)
    }
    return nil
  }

  private static func oauthErrorMessage(status: Int, data: Data) -> String {
    let fallback = "HTTP \(status)"
    guard let body = String(data: data, encoding: .utf8),
          !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return fallback
    }
    return "\(fallback): \(body)"
  }
}

enum KickAuthError: LocalizedError {
  case missingClientId
  case missingClientSecret
  case invalidRedirectURI
  case invalidAuthorizeURL
  case invalidCallback
  case couldNotStartSession
  case notSignedIn
  case tokenExpired
  case oauthRequestFailed(String)
  case invalidChannel
  case channelLookupFailed
  case chatSendFailed

  var errorDescription: String? {
    switch self {
    case .missingClientId: return "Kick Client IDが未設定です"
    case .missingClientSecret: return "Kick Client Secretが未設定です"
    case .invalidRedirectURI: return "Kick Redirect URIが不正です"
    case .invalidAuthorizeURL: return "Kick認証URLを作成できません"
    case .invalidCallback: return "Kick認証の戻りURLが不正です"
    case .couldNotStartSession: return "Kick認証を開始できません"
    case .notSignedIn: return "Kickにログインしていません"
    case .tokenExpired: return "Kickトークンが期限切れです"
    case .oauthRequestFailed(let message): return "Kick OAuthトークン取得に失敗しました: \(message)"
    case .invalidChannel: return "Kickチャンネルが不正です"
    case .channelLookupFailed: return "KickチャンネルIDを取得できません"
    case .chatSendFailed: return "Kickコメント送信に失敗しました"
    }
  }
}
