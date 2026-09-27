import Foundation

final class PlaybackCoordinator {
  static let shared = PlaybackCoordinator()
  private let views = NSHashTable<AnyObject>.weakObjects()
  private var lastResumeAllAt = Date.distantPast
  // 他アプリへの音声割り込み(電話・他アプリの再生)で全停止している間は true。この間は
  // タブ切替・回線復帰・作り直し等の自動 resumeAll やストール監視の押し直しで再生を奪い
  // 返さない。解除は割り込み終了(shouldResume)か、ユーザーがアプリへ戻った時だけ。
  private(set) var isSuspended = false

  func endSuspension() {
    isSuspended = false
  }

  func register(_ view: PlaybackResumable) {
    views.add(view as AnyObject)
  }

  func resumeAll() {
    // 同一ランループ内の重複呼び出し(reload/viewDidAppear/各リトライが重なる)を間引く。
    // リトライ間隔(0.2s〜)より十分短い 0.15s なので、意図的な再試行は阻害しない。
    guard !isSuspended else { return }
    let now = Date()
    guard now.timeIntervalSince(lastResumeAllAt) > 0.15 else { return }
    lastResumeAllAt = now
    for object in views.allObjects {
      (object as? PlaybackResumable)?.resumePlayback()
    }
  }

  func pauseAll() {
    isSuspended = true
    for object in views.allObjects {
      (object as? PlaybackResumable)?.pausePlayback()
    }
  }
}
