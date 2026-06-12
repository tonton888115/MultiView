package com.multiview

import androidx.media3.common.util.UnstableApi
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.common.MapBuilder
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.annotations.ReactProp

@UnstableApi
class NativeHlsPlayerManager : SimpleViewManager<NativeHlsPlayerView>() {
  override fun getName(): String = "NativeHlsPlayer"

  override fun createViewInstance(reactContext: ThemedReactContext): NativeHlsPlayerView =
    NativeHlsPlayerView(reactContext)

  @ReactProp(name = "sourceUrl")
  fun setSourceUrl(view: NativeHlsPlayerView, sourceUrl: String?) {
    view.setSourceUrl(sourceUrl)
  }

  @ReactProp(name = "headers")
  fun setHeaders(view: NativeHlsPlayerView, headers: ReadableMap?) {
    val next = mutableMapOf<String, String>()
    headers?.keySetIterator()?.let { iterator ->
      while (iterator.hasNextKey()) {
        val key = iterator.nextKey()
        if (!headers.isNull(key)) {
          next[key] = headers.getString(key) ?: ""
        }
      }
    }
    view.setHeaders(next)
  }

  @ReactProp(name = "paused", defaultBoolean = false)
  fun setPaused(view: NativeHlsPlayerView, paused: Boolean) {
    view.setPaused(paused)
  }

  @ReactProp(name = "muted", defaultBoolean = false)
  fun setMuted(view: NativeHlsPlayerView, muted: Boolean) {
    view.setMuted(muted)
  }

  @ReactProp(name = "volume", defaultFloat = 1f)
  fun setVolume(view: NativeHlsPlayerView, volume: Float) {
    view.setVolume(volume)
  }

  @ReactProp(name = "liveTargetOffsetMs", defaultInt = 2000)
  fun setLiveTargetOffsetMs(view: NativeHlsPlayerView, liveTargetOffsetMs: Int) {
    view.setLiveTargetOffsetMs(liveTargetOffsetMs)
  }

  @ReactProp(name = "resizeMode")
  fun setResizeMode(view: NativeHlsPlayerView, resizeMode: String?) {
    view.setResizeMode(resizeMode)
  }

  override fun getCommandsMap(): MutableMap<String, Int> =
    MapBuilder.of("play", COMMAND_PLAY, "pause", COMMAND_PAUSE, "reload", COMMAND_RELOAD)

  override fun receiveCommand(root: NativeHlsPlayerView, commandId: Int, args: ReadableArray?) {
    when (commandId) {
      COMMAND_PLAY -> root.play()
      COMMAND_PAUSE -> root.pause()
      COMMAND_RELOAD -> root.reload()
    }
  }

  override fun receiveCommand(root: NativeHlsPlayerView, commandId: String?, args: ReadableArray?) {
    when (commandId) {
      "play" -> root.play()
      "pause" -> root.pause()
      "reload" -> root.reload()
    }
  }

  override fun getExportedCustomDirectEventTypeConstants(): MutableMap<String, Any> =
    MapBuilder.of("onPlayerEvent", MapBuilder.of("registrationName", "onPlayerEvent"))

  override fun onDropViewInstance(view: NativeHlsPlayerView) {
    view.release()
    super.onDropViewInstance(view)
  }

  private companion object {
    const val COMMAND_PLAY = 1
    const val COMMAND_PAUSE = 2
    const val COMMAND_RELOAD = 3
  }
}
