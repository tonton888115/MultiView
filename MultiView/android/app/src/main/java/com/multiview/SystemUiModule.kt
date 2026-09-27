package com.multiview

import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.facebook.react.bridge.LifecycleEventListener
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.UiThreadUtil

// ビューモード(視聴タブの全画面)用。ステータスバー/ナビゲーションバーを隠し、
// 端からのスワイプで一時表示できる没入モードにする。バックグラウンド復帰で
// OS がバーを戻すことがあるため、有効中は onHostResume で掛け直す。
class SystemUiModule(private val reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext), LifecycleEventListener {
  @Volatile private var immersive = false

  init {
    reactContext.addLifecycleEventListener(this)
  }

  override fun getName(): String = "SystemUi"

  @ReactMethod
  fun setImmersive(enabled: Boolean) {
    immersive = enabled
    applyImmersive()
  }

  private fun applyImmersive() {
    UiThreadUtil.runOnUiThread {
      val window = reactContext.currentActivity?.window ?: return@runOnUiThread
      val controller = WindowCompat.getInsetsController(window, window.decorView)
      if (immersive) {
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller.hide(WindowInsetsCompat.Type.systemBars())
      } else {
        controller.show(WindowInsetsCompat.Type.systemBars())
      }
    }
  }

  override fun onHostResume() {
    if (immersive) {
      applyImmersive()
    }
  }

  override fun onHostPause() = Unit

  override fun onHostDestroy() = Unit

  override fun invalidate() {
    reactContext.removeLifecycleEventListener(this)
    super.invalidate()
  }
}
