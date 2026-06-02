import Foundation

final class PlaybackCoordinator {
  static let shared = PlaybackCoordinator()
  private let views = NSHashTable<AnyObject>.weakObjects()
  private var lastResumeAllAt = Date.distantPast

  func register(_ view: PlaybackResumable) {
    views.add(view as AnyObject)
  }

  func resumeAll() {
    // 同一ランループ内の重複呼び出し(reload/viewDidAppear/各リトライが重なる)を間引く。
    // リトライ間隔(0.2s〜)より十分短い 0.15s なので、意図的な再試行は阻害しない。
    let now = Date()
    guard now.timeIntervalSince(lastResumeAllAt) > 0.15 else { return }
    lastResumeAllAt = now
    for object in views.allObjects {
      (object as? PlaybackResumable)?.resumePlayback()
    }
  }

  func pauseAll() {
    for object in views.allObjects {
      (object as? PlaybackResumable)?.pausePlayback()
    }
  }
}
