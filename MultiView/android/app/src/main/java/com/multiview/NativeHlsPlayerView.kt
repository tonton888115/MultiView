package com.multiview

import android.content.Context
import android.net.Uri
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
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView

@UnstableApi
class NativeHlsPlayerView(context: Context) : FrameLayout(context) {
  private val exoPlayer = ExoPlayer.Builder(context).build()
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

  private fun emit(type: String, message: String) {
    // RN 0.82 runs this app in bridgeless mode by default. The legacy
    // RCTEventEmitter path logs errors there, so JS keeps status from the
    // resolver and native commands until this view is migrated to Fabric events.
  }

  private companion object {
    const val DEFAULT_USER_AGENT =
      "Mozilla/5.0 (Linux; Android 15; Pixel 9 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36"
  }
}
