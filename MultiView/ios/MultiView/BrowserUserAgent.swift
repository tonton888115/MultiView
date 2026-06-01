enum BrowserUserAgent {
  static let mobileSafari = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
  static let mobileWebKit = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15"
  static let desktopSafari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
  static let youtubeIOSVersion = "21.17.3"
  static let youtubeAndroidVersion = "20.19.35"

  static func youtubeIOS(version: String) -> String {
    "com.google.ios.youtube/\(version) (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X; ja_JP)"
  }

  static func youtubeAndroid(version: String) -> String {
    "com.google.android.youtube/\(version) (Linux; U; Android 15) gzip"
  }
}
