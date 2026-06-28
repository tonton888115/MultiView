package com.multiview

import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod

class GiftSoundModule(context: ReactApplicationContext) : ReactContextBaseJavaModule(context) {
  private val mainHandler = Handler(Looper.getMainLooper())

  override fun getName(): String = "GiftSound"

  @ReactMethod
  fun play() {
    mainHandler.post {
      try {
        val tone = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 65)
        tone.startTone(ToneGenerator.TONE_PROP_ACK, 180)
        mainHandler.postDelayed({ tone.release() }, 350)
      } catch (_: Throwable) {
        // Audio focus or device policy may suppress notification tones.
      }
    }
  }
}
