// ニコ生 NDGR コメントの中継。コメントは隠しセッション WebView 内(niconico.ts の
// niconicoSessionScript)で取得され、NiconicoNativePlayer(App.tsx) が postMessage を受けて
// pushNiconicoComment を呼ぶ。DanmakuOverlay は chat.ts 経由で subscribe して弾幕表示する。
// raidFollow と同様、プレイヤー階層を跨ぐ通知を props 多層伝播せず module-level で配る。

export type NiconicoComment = {text: string; author?: string};
type Listener = (comment: NiconicoComment) => void;

const listeners = new Map<string, Set<Listener>>();

export function subscribeNiconicoComments(programId: string, listener: Listener): () => void {
  const key = programId.trim();
  let set = listeners.get(key);
  if (!set) {
    set = new Set();
    listeners.set(key, set);
  }
  set.add(listener);
  return () => {
    const current = listeners.get(key);
    if (!current) {
      return;
    }
    current.delete(listener);
    if (current.size === 0) {
      listeners.delete(key);
    }
  };
}

export function pushNiconicoComment(programId: string, comment: NiconicoComment): void {
  const set = listeners.get(programId.trim());
  if (!set) {
    return;
  }
  set.forEach(listener => {
    try {
      listener(comment);
    } catch {
      // listener errors must not break the session
    }
  });
}
