package com.multiview

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.TextureView
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.ui.AspectRatioFrameLayout
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.LifecycleEventListener
import com.facebook.react.bridge.ReactContext
import com.facebook.react.bridge.WritableMap
import com.facebook.react.uimanager.UIManagerHelper
import com.facebook.react.uimanager.events.Event

internal fun mergeCookieHeaders(explicitHeader: String?, fallbackHeader: String?): String? {
  val cookies = linkedMapOf<String, String>()

  fun append(header: String?, overwrite: Boolean) {
    header
      ?.split(';')
      ?.forEach { rawCookie ->
        val cookie = rawCookie.trim()
        val separator = cookie.indexOf('=')
        if (separator <= 0) {
          return@forEach
        }
        val name = cookie.substring(0, separator).trim()
        val value = cookie.substring(separator + 1).trim()
        if (name.isNotEmpty() && (overwrite || !cookies.containsKey(name))) {
          cookies[name] = value
        }
      }
  }

  // The stream response is authoritative. CookieManager may still contain an older value for
  // the same name, so it only fills names that the WebSocket response did not provide.
  append(explicitHeader, overwrite = true)
  append(fallbackHeader, overwrite = false)
  return cookies.takeIf { it.isNotEmpty() }
    ?.entries
    ?.joinToString("; ") { (name, value) -> "$name=$value" }
}

@UnstableApi
class NativeHlsPlayerView(context: Context) : FrameLayout(context), LifecycleEventListener {
  private val reactContext = context as? ReactContext
  private val trackSelector = DefaultTrackSelector(context)
  private val exoPlayer = ExoPlayer.Builder(context).setTrackSelector(trackSelector).build()
  // PlayerView の既定 SurfaceView は RN の動的レイアウトでサイズ追従に失敗し、映像が
  // 縮んで中央に出る/潰れることがある。通常ビューとして正しくリサイズされる TextureView を
  // AspectRatioFrameLayout に入れ、アスペクト比は onVideoSizeChanged で設定する。
  private val contentFrame = AspectRatioFrameLayout(context).apply {
    setResizeMode(AspectRatioFrameLayout.RESIZE_MODE_FIT)
    layoutParams = LayoutParams(
      ViewGroup.LayoutParams.MATCH_PARENT,
      ViewGroup.LayoutParams.MATCH_PARENT,
      Gravity.CENTER,
    )
  }
  private val textureView = TextureView(context).apply {
    layoutParams = FrameLayout.LayoutParams(
      ViewGroup.LayoutParams.MATCH_PARENT,
      ViewGroup.LayoutParams.MATCH_PARENT,
      Gravity.CENTER,
    )
  }

  private var sourceUrl: String? = null
  private var preparedUrl: String? = null
  private var headers: Map<String, String> = emptyMap()
  private var sourcePropertiesDirty = false
  private var released = false
  private var paused = false
  private var viewingActive = true
  private var muted = false
  private var volume = 1f
  private var liveTargetOffsetMs = 2_000L
  private var maxBitrate = 0
  private val mainHandler = Handler(Looper.getMainLooper())
  private var progressWatchdogRunning = false
  private var lastProgressPositionMs = C.TIME_UNSET
  private var lastProgressAtMs = 0L
  private var lastStallRecoveryAtMs: Long? = null
  private var videoOutputRebindAttempts = 0
  private val rebindVideoOutput = object : Runnable {
    override fun run() {
      if (released || exoPlayer.currentMediaItem == null) {
        return
      }
      if (!isAttachedToWindow || !textureView.isAvailable) {
        // Fold の展開/折りたたみ直後は surface がまだ戻っていないことがある。一回で
        // 諦めると恒久黒画面になるため、available になるまで有限回だけ再試行する。
        if (videoOutputRebindAttempts < VIDEO_OUTPUT_REBIND_MAX_ATTEMPTS) {
          videoOutputRebindAttempts += 1
          mainHandler.postDelayed(this, VIDEO_OUTPUT_REBIND_RETRY_DELAY_MS)
        }
        return
      }
      videoOutputRebindAttempts = 0
      exoPlayer.clearVideoTextureView(textureView)
      exoPlayer.setVideoTextureView(textureView)
      if (!paused) {
        exoPlayer.playWhenReady = true
        exoPlayer.play()
        startProgressWatchdog()
      }
    }
  }
  private val progressWatchdog = object : Runnable {
    override fun run() {
      if (!progressWatchdogRunning) {
        return
      }
      val now = SystemClock.elapsedRealtime()
      if (paused || exoPlayer.currentMediaItem == null) {
        resetProgressSample(now)
      } else if (exoPlayer.playbackState != Player.STATE_IDLE && exoPlayer.playbackState != Player.STATE_ENDED) {
        val position = exoPlayer.currentPosition
        if (lastProgressPositionMs == C.TIME_UNSET || position > lastProgressPositionMs + MIN_PROGRESS_MS) {
          lastProgressPositionMs = position
          lastProgressAtMs = now
        } else {
          val cooldownElapsed = lastStallRecoveryAtMs?.let { now - it >= STALL_RECOVERY_COOLDOWN_MS } ?: true
          if (now - lastProgressAtMs >= STALL_THRESHOLD_MS && cooldownElapsed) {
            lastStallRecoveryAtMs = now
            lastProgressAtMs = now
            emit("error", "stall")
          }
        }
      } else {
        resetProgressSample(now)
      }
      if (progressWatchdogRunning) {
        mainHandler.postDelayed(this, PROGRESS_SAMPLE_INTERVAL_MS)
      }
    }
  }

  init {
    reactContext?.addLifecycleEventListener(this)
    setBackgroundColor(android.graphics.Color.BLACK)
    exoPlayer.setWakeMode(C.WAKE_MODE_NETWORK)
    contentFrame.addView(textureView)
    addView(contentFrame)
    exoPlayer.setVideoTextureView(textureView)
    exoPlayer.addListener(object : Player.Listener {
      override fun onVideoSizeChanged(videoSize: VideoSize) {
        val w = videoSize.width
        val h = videoSize.height
        val ratio = if (w == 0 || h == 0) 0f else w * videoSize.pixelWidthHeightRatio / h
        contentFrame.setAspectRatio(ratio)
      }

      override fun onRenderedFirstFrame() {
        emit("firstFrame", "rendered")
      }

      override fun onPlaybackStateChanged(playbackState: Int) {
        val status = when (playbackState) {
          Player.STATE_BUFFERING -> "buffering"
          Player.STATE_READY -> if (exoPlayer.isPlaying) "playing" else "ready"
          Player.STATE_ENDED -> "ended"
          else -> "idle"
        }
        emit("status", status)
      }

      override fun onIsPlayingChanged(isPlaying: Boolean) {
        val status = if (isPlaying) {
          "playing"
        } else if (paused) {
          "paused"
        } else {
          when (exoPlayer.playbackState) {
            Player.STATE_BUFFERING -> "buffering"
            Player.STATE_READY -> "ready"
            Player.STATE_ENDED -> "ended"
            else -> "idle"
          }
        }
        emit("status", status)
      }

      override fun onPlayerError(error: PlaybackException) {
        // ライブ停滞後に再生位置がライブ窓から外れた(BEHIND_LIVE_WINDOW)場合は、iOS の
        // LiveEdgeCatchUp と同様にその場でライブエッジへ戻して再準備する。フル再マウント
        // 無しで自動再開でき、失敗すれば次の onPlayerError が JS へ通知される。
        if (
          error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW &&
          !released &&
          exoPlayer.currentMediaItem != null
        ) {
          exoPlayer.seekToDefaultPosition()
          exoPlayer.prepare()
          return
        }
        emit("error", error.localizedMessage ?: error.errorCodeName)
      }
    })
  }

  fun setSourceUrl(next: String?) {
    val normalized = next?.trim()?.takeIf { it.isNotEmpty() }
    if (sourceUrl == normalized) {
      return
    }
    sourceUrl = normalized
    sourcePropertiesDirty = true
  }

  fun setHeaders(next: Map<String, String>) {
    if (headers == next) {
      return
    }
    headers = next.toMap()
    sourcePropertiesDirty = true
  }

  fun setPaused(next: Boolean) {
    paused = next
    exoPlayer.playWhenReady = !paused
    if (paused) {
      exoPlayer.pause()
      stopProgressWatchdog()
    } else if (exoPlayer.currentMediaItem != null) {
      exoPlayer.play()
      startProgressWatchdog()
    }
  }

  fun setViewingActive(next: Boolean) {
    val becameActive = !viewingActive && next
    viewingActive = next
    if (becameActive && !released && exoPlayer.currentMediaItem != null) {
      scheduleVideoOutputRebind()
      if (exoPlayer.playbackState == Player.STATE_IDLE) {
        emit("error", "resume-idle")
      }
    }
  }

  fun setMuted(next: Boolean) {
    muted = next
    applyVolume()
  }

  fun setVolume(next: Float) {
    volume = next.coerceIn(0f, 1f)
    applyVolume()
  }

  fun setLiveTargetOffsetMs(next: Int) {
    val clamped = next.coerceIn(1_500, 30_000).toLong()
    if (liveTargetOffsetMs == clamped) {
      return
    }
    liveTargetOffsetMs = clamped
    sourcePropertiesDirty = true
  }

  // iOS の NetworkQuality.effectivePeakBitRate(エコノミー≈900kbps、3本以上で自動)に相当。
  // エコノミーは 640x360 も上限にして通信量を落とす。制約超過しかない配信でも再生は継続する。
  fun setMaxBitrate(next: Int) {
    if (maxBitrate == next) {
      return
    }
    maxBitrate = next
    val builder = trackSelector.buildUponParameters()
      .setExceedVideoConstraintsIfNecessary(true)
    if (next > 0) {
      builder
        .setMaxVideoBitrate(next)
        .clearVideoSizeConstraints()
        .setViewportSize(640, 360, true)
    } else {
      builder
        .setMaxVideoBitrate(Int.MAX_VALUE)
        .clearVideoSizeConstraints()
        .clearViewportSizeConstraints()
    }
    trackSelector.setParameters(
      builder,
    )
  }

  fun setResizeMode(next: String?) {
    contentFrame.resizeMode = when (next) {
      "cover" -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
      "stretch" -> AspectRatioFrameLayout.RESIZE_MODE_FILL
      else -> AspectRatioFrameLayout.RESIZE_MODE_FIT
    }
  }

  fun play() {
    paused = false
    exoPlayer.playWhenReady = true
    exoPlayer.play()
    startProgressWatchdog()
  }

  fun pause() {
    paused = true
    exoPlayer.pause()
    stopProgressWatchdog()
  }

  fun reload() {
    sourcePropertiesDirty = false
    prepareIfNeeded(force = true)
  }

  // React may call sourceUrl, headers, and liveTargetOffsetMs setters in any order during one
  // transaction. Building a MediaSource in each setter starts multiple overlapping loads with
  // partial configuration, so the manager commits the final snapshot once after all props land.
  fun commitSourceProperties() {
    if (!sourcePropertiesDirty) {
      return
    }
    sourcePropertiesDirty = false
    prepareIfNeeded(force = sourceUrl != null)
  }

  fun release() {
    if (released) {
      return
    }
    released = true
    stopProgressWatchdog()
    mainHandler.removeCallbacks(rebindVideoOutput)
    reactContext?.removeLifecycleEventListener(this)
    exoPlayer.release()
  }

  override fun onHostResume() {
    // A TextureView surface may be destroyed while the Activity is backgrounded
    // or reconfigured even though ExoPlayer keeps advancing. Rebind the output
    // explicitly so foreground playback cannot remain audio-only/black forever.
    scheduleVideoOutputRebind()
    // 致命的エラー後の ExoPlayer は IDLE で停止し、以後イベントを出さない。
    // バックグラウンド中に届かなかった/間引かれたエラーはフォアグラウンド復帰時に
    // 再通知して、JS 側の自動リロード(iOS の resumeAll 相当)へ確実に繋ぐ。
    if (!released && exoPlayer.currentMediaItem != null && exoPlayer.playbackState == Player.STATE_IDLE) {
      emit("error", "resume-idle")
    }
  }

  override fun onHostPause() = Unit

  override fun onHostDestroy() = Unit

  override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
    super.onSizeChanged(width, height, oldWidth, oldHeight)
    if (width > 0 && height > 0 && (width != oldWidth || height != oldHeight)) {
      // Fold/unfold is handled as a configuration change by MainActivity, so it does not produce
      // an AppState transition or onHostResume callback. Reattach the existing TextureView after
      // the new window bounds settle; otherwise ExoPlayer can keep advancing against a stale
      // output surface and leave a permanently black pane.
      scheduleVideoOutputRebind()
    }
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    // Fold/マルチウィンドウ遷移で view が付け直された場合も出力を確実に戻す。
    if (!released && exoPlayer.currentMediaItem != null) {
      scheduleVideoOutputRebind()
    }
  }

  private fun scheduleVideoOutputRebind() {
    videoOutputRebindAttempts = 0
    mainHandler.removeCallbacks(rebindVideoOutput)
    mainHandler.postDelayed(rebindVideoOutput, VIDEO_OUTPUT_REBIND_DELAY_MS)
  }

  private fun applyVolume() {
    exoPlayer.volume = if (muted) 0f else volume
  }

  private fun prepareIfNeeded(force: Boolean) {
    val url = sourceUrl
    if (url == null) {
      stopProgressWatchdog()
      preparedUrl = null
      exoPlayer.stop()
      exoPlayer.clearMediaItems()
      emit("status", "idle")
      return
    }
    if (!force && url == preparedUrl) {
      return
    }
    preparedUrl = url
    emit("status", "loading")
    exoPlayer.setMediaSource(mediaSourceFor(url))
    exoPlayer.prepare()
    exoPlayer.playWhenReady = !paused
    applyVolume()
    if (!paused) {
      startProgressWatchdog()
    }
  }

  private fun startProgressWatchdog() {
    if (progressWatchdogRunning) {
      resetProgressSample()
      return
    }
    progressWatchdogRunning = true
    resetProgressSample()
    mainHandler.postDelayed(progressWatchdog, PROGRESS_SAMPLE_INTERVAL_MS)
  }

  private fun stopProgressWatchdog() {
    progressWatchdogRunning = false
    mainHandler.removeCallbacks(progressWatchdog)
    resetProgressSample()
  }

  private fun resetProgressSample(now: Long = SystemClock.elapsedRealtime()) {
    lastProgressPositionMs = C.TIME_UNSET
    lastProgressAtMs = now
  }

  private fun mediaSourceFor(url: String): MediaSource {
    val requestHeaders = headers.filterKeys { key -> key.lowercase() != "user-agent" }.toMutableMap()
    // セッション WebView が確立した Cookie(httpOnly 含む)を CookieManager から補完する。
    // document.cookie は httpOnly を読めず、ツイキャス等の HLS セグメントが 401 になるため、
    // JS から渡る最新値を優先し、CookieManager は不足名だけを補完して重複名を送らない。
    val explicitCookie = requestHeaders.entries
      .firstOrNull { it.key.equals("Cookie", ignoreCase = true) }
      ?.value
      ?.takeIf { it.isNotBlank() }
    requestHeaders.keys.filter { it.equals("Cookie", ignoreCase = true) }.toList()
      .forEach { requestHeaders.remove(it) }
    val webCookie = try {
      android.webkit.CookieManager.getInstance().getCookie(url)?.takeIf { it.isNotBlank() }
    } catch (_: Throwable) {
      null
    }
    mergeCookieHeaders(explicitCookie, webCookie)?.let {
      requestHeaders["Cookie"] = it
    }
    val dataSourceFactory = DefaultHttpDataSource.Factory()
      .setAllowCrossProtocolRedirects(true)
      .setUserAgent(headers["User-Agent"] ?: DEFAULT_USER_AGENT)
      .setDefaultRequestProperties(requestHeaders)
    val mediaItem = MediaItem.Builder()
      .setUri(Uri.parse(url))
      .setLiveConfiguration(
        MediaItem.LiveConfiguration.Builder()
          .setTargetOffsetMs(liveTargetOffsetMs)
          .setMinPlaybackSpeed(0.97f)
          .setMaxPlaybackSpeed(1.03f)
          .build(),
      )
      .build()
    val lower = url.lowercase()
    return if (lower.contains(".m3u8") || lower.contains("hls")) {
      HlsMediaSource.Factory(dataSourceFactory)
        .setAllowChunklessPreparation(true)
        .createMediaSource(mediaItem)
    } else {
      ProgressiveMediaSource.Factory(dataSourceFactory).createMediaSource(mediaItem)
    }
  }

  // Fabric(新アーキ)でも旧アーキでも動く EventDispatcher 経由で onPlayerEvent を送る。
  // 旧来の RCTEventEmitter は bridgeless でエラーになるため使わない。
  private fun emit(type: String, message: String) {
    val reactContext = context as? ReactContext ?: return
    val dispatcher = UIManagerHelper.getEventDispatcherForReactTag(reactContext, id) ?: return
    val surfaceId = UIManagerHelper.getSurfaceId(this)
    val payload = Arguments.createMap().apply {
      putString("type", type)
      putString("message", message)
    }
    dispatcher.dispatchEvent(PlayerEvent(surfaceId, id, payload))
  }

  private companion object {
    const val PROGRESS_SAMPLE_INTERVAL_MS = 3_000L
    const val STALL_THRESHOLD_MS = 12_000L
    const val STALL_RECOVERY_COOLDOWN_MS = 20_000L
    const val MIN_PROGRESS_MS = 250L
    const val VIDEO_OUTPUT_REBIND_DELAY_MS = 100L
    const val VIDEO_OUTPUT_REBIND_RETRY_DELAY_MS = 250L
    const val VIDEO_OUTPUT_REBIND_MAX_ATTEMPTS = 20
    const val DEFAULT_USER_AGENT =
      "Mozilla/5.0 (Linux; Android 15; Pixel 9 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36"
  }
}

private class PlayerEvent(
  surfaceId: Int,
  viewId: Int,
  private val payload: WritableMap,
) : Event<PlayerEvent>(surfaceId, viewId) {
  override fun getEventName(): String = "onPlayerEvent"
  override fun getEventData(): WritableMap = payload
}
