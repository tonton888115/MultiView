import Foundation

// Player capability protocols, shared by the per-platform native player views
// and the grid / focused UI. Extracted from AppDelegate.swift.

protocol PlaybackResumable: AnyObject {
  func resumePlayback()
  func pausePlayback()
}

extension PlaybackResumable {
  func pausePlayback() {}
}

protocol PlaybackStoppable: AnyObject {
  func stopPlayback()
}

// 回線復帰時に作り直すべき状態(回線待ち・Webフォールバック中など、ネイティブ再生が
// 失われたまま)かを報告する。視聴タブは該当セルだけを作り直す。
protocol PlaybackRecoverable: AnyObject {
  var needsRecoveryOnNetworkRestore: Bool { get }
}

protocol AudioControllable: AnyObject {
  func setPlaybackVolume(_ volume: Float)
}

// A player that can post a chat comment for its own stream (using the logged-in
// session it already holds), so a cell can send without leaving the grid.
protocol CommentPostable: AnyObject {
  func postComment(_ text: String, completion: @escaping (Result<Void, Error>) -> Void)
}

protocol CommentEchoDisplay: AnyObject {
  func emitOwnComment(_ text: String)
}
