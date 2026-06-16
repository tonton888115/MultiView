package com.multiview

import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod

// JS から背景音声サービスを開始/停止する。配信が1本以上 & 音声ONの間だけ前面で start し、
// バックグラウンドに入ってもプロセスを生かして音声を継続させる。
class PlaybackServiceModule(private val reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext) {
  override fun getName(): String = "PlaybackService"

  @ReactMethod
  fun start() {
    try {
      PlaybackService.start(reactContext)
    } catch (_: Throwable) {
      // FGS 起動が拒否される環境(古いOS/権限)でもアプリは落とさない。
    }
  }

  @ReactMethod
  fun stop() {
    try {
      PlaybackService.stop(reactContext)
    } catch (_: Throwable) {
    }
  }

  // NativeEventEmitter 警告抑止用(未使用)。
  @ReactMethod
  fun addListener(eventName: String) {}

  @ReactMethod
  fun removeListeners(count: Int) {}
}
