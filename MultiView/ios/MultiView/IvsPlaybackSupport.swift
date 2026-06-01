import Foundation
import UIKit
import AVFoundation
import AmazonIVSPlayer

// Shared Amazon IVS playback helpers used by Kick and Twitch.
protocol IVSPlaybackHost: AnyObject {
  var ivsPlayer: IVSPlayer? { get set }
  var ivsPlayerLayer: IVSPlayerLayer? { get set }
  var ivsBufferingRecoveryWork: DispatchWorkItem? { get set }
  var usingIvsPlayback: Bool { get set }
  var playerLayer: AVPlayerLayer { get }
  var settings: AppSettings { get }
  var playbackVolume: Float { get }
}

extension IVSPlaybackHost where Self: UIView {
  func layoutIvsLayer() {
    ivsPlayerLayer?.frame = bounds
  }

  func resumeIvsPlaybackIfActive() -> Bool {
    guard let ivsPlayer, usingIvsPlayback else { return false }
    applyIvsAudio()
    ivsPlayer.play()
    return true
  }

  func pauseIvsPlayback() {
    ivsPlayer?.pause()
  }

  func attachIvsPlayer(_ ivs: IVSPlayer) {
    teardownIvsPlayback(removeLayer: false)
    ivsPlayer = ivs
    usingIvsPlayback = true
    applyIvsAudio()

    let layer = ivsPlayerLayer ?? IVSPlayerLayer(player: nil)
    layer.player = ivs
    layer.videoGravity = .resizeAspect
    layer.frame = bounds
    layer.isHidden = false
    if layer.superlayer == nil {
      self.layer.insertSublayer(layer, above: playerLayer)
    }
    ivsPlayerLayer = layer
    playerLayer.isHidden = true
  }

  func teardownIvsPlayback(removeLayer: Bool) {
    ivsBufferingRecoveryWork?.cancel()
    ivsBufferingRecoveryWork = nil
    usingIvsPlayback = false
    if let ivsPlayer {
      ivsPlayer.delegate = nil
      ivsPlayer.pause()
      ivsPlayer.load(nil as URL?)
    }
    ivsPlayer = nil
    ivsPlayerLayer?.player = nil
    ivsPlayerLayer?.isHidden = true
    if removeLayer {
      ivsPlayerLayer?.removeFromSuperlayer()
      ivsPlayerLayer = nil
    }
    playerLayer.isHidden = false
  }

  func applyIvsAudio() {
    guard let ivsPlayer else { return }
    let effectiveVolume = settings.playAudio ? playbackVolume : 0
    ivsPlayer.volume = effectiveVolume
    ivsPlayer.muted = effectiveVolume <= 0
  }

  func ownsIvsPlayer(_ player: IVSPlayer) -> Bool {
    guard let ivsPlayer else { return false }
    return player === ivsPlayer && usingIvsPlayback
  }
}
