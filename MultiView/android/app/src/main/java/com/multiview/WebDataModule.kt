package com.multiview

import android.webkit.CookieManager
import android.webkit.WebStorage
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.UiThreadUtil

// iOS Screens.swift の confirmClearWebData(WebLoginCookies.clearAll) と
// NiconicoSession.logout に相当する WebView データ削除。CookieManager /
// WebStorage は WebView プロバイダ初期化を伴うため UI スレッドで触る。
class WebDataModule(reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext) {

  override fun getName(): String = "WebData"

  // 全ドメインの WebView Cookie と Web ストレージ(localStorage 等)を削除する。
  // OAuth 連携(AsyncStorage 保存)には触れない — iOS と同じ責務分担。
  @ReactMethod
  fun clearWebData(promise: Promise) {
    UiThreadUtil.runOnUiThread {
      try {
        val cookieManager = CookieManager.getInstance()
        cookieManager.removeAllCookies(null)
        cookieManager.flush()
        WebStorage.getInstance().deleteAllData()
        promise.resolve(null)
      } catch (error: Exception) {
        promise.reject("web_data_clear_failed", error)
      }
    }
  }

  // 指定ドメイン(例: "nicovideo.jp")の Cookie だけを失効させる。Android の
  // CookieManager にはドメイン単位の削除 API が無いため、代表 URL から Cookie 名を
  // 集めて過去日付の Set-Cookie で上書きする(iOS NiconicoSession.logout 相当)。
  @ReactMethod
  fun clearCookiesForDomain(domain: String, promise: Promise) {
    UiThreadUtil.runOnUiThread {
      try {
        val bare = domain.trim().removePrefix(".")
        if (bare.isEmpty()) {
          promise.reject("web_data_invalid_domain", "ドメインが指定されていません")
          return@runOnUiThread
        }
        val cookieManager = CookieManager.getInstance()
        val urls = listOf(
          "https://www.$bare",
          "https://$bare",
          "https://live.$bare",
          "https://account.$bare",
        )
        val names = mutableSetOf<String>()
        for (url in urls) {
          val header = cookieManager.getCookie(url) ?: continue
          header.split(';').forEach { pair ->
            val name = pair.substringBefore('=').trim()
            if (name.isNotEmpty()) {
              names.add(name)
            }
          }
        }
        val expires = "Expires=Thu, 01 Jan 1970 00:00:00 GMT"
        for (url in urls) {
          for (name in names) {
            // ドメイン Cookie(.nicovideo.jp)とホスト限定 Cookie の両方を失効させる。
            cookieManager.setCookie(url, "$name=; Domain=.$bare; Path=/; $expires")
            cookieManager.setCookie(url, "$name=; Path=/; $expires")
          }
        }
        cookieManager.flush()
        promise.resolve(null)
      } catch (error: Exception) {
        promise.reject("web_data_clear_domain_failed", error)
      }
    }
  }
}
