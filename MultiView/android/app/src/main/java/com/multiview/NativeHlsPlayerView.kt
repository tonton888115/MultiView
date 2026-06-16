package com.multiview

import android.content.Context
import android.net.Uri
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReactContext
import com.facebook.react.bridge.WritableMap
import com.facebook.react.uimanager.UIManagerHelper
import com.facebook.react.uimanager.events.Event

@UnstableApi
class NativeHlsPlayerView(context: Context) : FrameLayout(context) {
  private val trackSelector = DefaultTrackSelector(context)
  private val exoPlayer = ExoPlayer.Builder(context).setTrackSelector(trackSelector).build()
  private val playerView = PlayerView(context).apply {
    useController = false
    resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
    player = exoPlayer
    setShutterBackgroundColor(android.graphics.Color.BLACK)
    layoutParams = LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
  }

  private var sourceUrl: String? = null
  private var preparedUrl: String? = null
  private var headers: Map<String, String> = emptyMap()
  private var paused = false
  private var muted = false
  private var volume = 1f
  private var liveTargetOffsetMs = 2_000L
  private var maxBitrate = 0

  // React(Fabric)は子ビューのレイアウトを自前で行わないため、host のサイズ変更が
  // PlayerView/SurfaceView に伝播せず映像が半分に潰れる/位置がずれる。requestLayout の度に
  // 自分自身を再measure/layout して子へ正しいサイズを伝える(RN カスタムビュー定番の対処)。
  private val measureAndLayout = Runnable {
    measure(
      View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
      View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY),
    )
    layout(left, top, right, bottom)
  }

  override fun requestLayout() {
    super.requestLayout()
    post(measureAndLayout)
  }

  init {
    setBackgroundColor(android.graphics.Color.BLACK)
    addView(playerView)
    exoPlayer.addListener(object : Player.Listener {
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
        emit("status", if (isPlaying) "playing" else "paused")
      }

      override fun onPlayerError(error: PlaybackException) {
        emit("error", error.localizedMessage ?: error.errorCodeName)
      }
    })
  }

  fun setSourceUrl(next: String?) {
    sourceUrl = next?.trim()?.takeIf { it.isNotEmpty() }
    prepareIfNeeded(force = true)
  }

  fun setHeaders(next: Map<String, String>) {
    if (headers == next) {
      return
    }
    headers = next
    prepareIfNeeded(force = sourceUrl != null)
  }

  fun setPaused(next: Boolean) {
    paused = next
    exoPlayer.playWhenReady = !paused
    if (paused) {
      exoPlayer.pause()
    } else if (exoPlayer.currentMediaItem != null) {
      exoPlayer.play()
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
    prepareIfNeeded(force = sourceUrl != null)
  }

  // iOS の NetworkQuality.effectivePeakBitRate(エコノミー≈900kbps、3本以上で自動)に相当。
  // 0 は無制限。HLS の各バリアントから上限以下の最高画質を ExoPlayer が選ぶ。
  fun setMaxBitrate(next: Int) {
    if (maxBitrate == next) {
      return
    }
    maxBitrate = next
    trackSelector.setParameters(
      trackSelector.buildUponParameters()
        .setMaxVideoBitrate(if (next > 0) next else Int.MAX_VALUE),
    )
  }

  fun setResizeMode(next: String?) {
    playerView.resizeMode = when (next) {
      "cover" -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
      "stretch" -> AspectRatioFrameLayout.RESIZE_MODE_FILL
      else -> AspectRatioFrameLayout.RESIZE_MODE_FIT
    }
  }

  fun play() {
    paused = false
    exoPlayer.playWhenReady = true
    exoPlayer.play()
  }

  fun pause() {
    paused = true
    exoPlayer.pause()
  }

  fun reload() {
    prepareIfNeeded(force = true)
  }

  fun release() {
    exoPlayer.release()
  }

  private fun applyVolume() {
    exoPlayer.volume = if (muted) 0f else volume
  }

  private fun prepareIfNeeded(force: Boolean) {
    val url = sourceUrl
    if (url == null) {
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
  }

  private fun mediaSourceFor(url: String): MediaSource {
    val requestHeaders = headers.filterKeys { key -> key.lowercase() != "user-agent" }
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
