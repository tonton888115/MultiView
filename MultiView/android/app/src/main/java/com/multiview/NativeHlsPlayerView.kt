package com.multiview

import android.content.Context
import android.net.Uri
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
import com.facebook.react.bridge.ReactContext
import com.facebook.react.bridge.WritableMap
import com.facebook.react.uimanager.UIManagerHelper
import com.facebook.react.uimanager.events.Event

@UnstableApi
class NativeHlsPlayerView(context: Context) : FrameLayout(context) {
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
  private var paused = false
  private var muted = false
  private var volume = 1f
  private var liveTargetOffsetMs = 2_000L
  private var maxBitrate = 0
  // ソース/ヘッダー/遅延目標の変更は印だけ付け、props 1回分の適用後にまとめて prepare する。
  private var pendingPrepare = false
  private var liveWindowRecoveries = 0
  private var liveWindowRecoveryWindowStart = 0L

  init {
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
        if (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW && allowLiveWindowRecovery()) {
          // 通信の詰まり等でライブ端から遅れすぎただけ。ライブ端へ戻して即座に再開する
          // (JS 側の自動復旧は最大45秒待つので、その間黒画面になっていた)。
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
    // 新アーキ(Fabric)では props が1つ変わるだけでも全 props が再送される。同じ URL で
    // 毎回 prepare し直していたため、音量変更などのたびに配信が最初から読み込み直されていた。
    if (normalized == sourceUrl) {
      return
    }
    sourceUrl = normalized
    schedulePrepare()
  }

  fun setHeaders(next: Map<String, String>) {
    if (headers == next) {
      return
    }
    headers = next
    if (sourceUrl != null) {
      schedulePrepare()
    }
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
    if (sourceUrl != null) {
      schedulePrepare()
    }
  }

  // ViewManager.onAfterUpdateTransaction から props 1回分の適用後に呼ばれる。生成直後に
  // sourceUrl / headers / liveTargetOffsetMs が順不同で届いても prepare は1回で済む
  // (旧実装は最大3回 prepare し、ヘッダー無しの最初の要求が失敗することもあった)。
  fun applyPendingChanges() {
    if (!pendingPrepare) {
      return
    }
    pendingPrepare = false
    prepareIfNeeded(force = true)
  }

  private fun schedulePrepare() {
    if (pendingPrepare) {
      return
    }
    pendingPrepare = true
    // 念のため、トランザクション完了通知が来ない経路でも次のループで確実に反映する。
    post { applyPendingChanges() }
  }

  private fun allowLiveWindowRecovery(): Boolean {
    val now = android.os.SystemClock.elapsedRealtime()
    if (now - liveWindowRecoveryWindowStart > 60_000L) {
      liveWindowRecoveryWindowStart = now
      liveWindowRecoveries = 0
    }
    liveWindowRecoveries += 1
    return liveWindowRecoveries <= 5
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
  }

  fun pause() {
    paused = true
    exoPlayer.pause()
  }

  fun reload() {
    pendingPrepare = false
    prepareIfNeeded(force = true)
  }

  fun release() {
    pendingPrepare = false
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
