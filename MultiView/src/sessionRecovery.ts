export const sessionConnectTimeoutMs = 20_000;
export const playerStallTimeoutMs = 25_000;
export const nativeFirstFrameTimeoutMs = 12_000;
// 同じ障害に対するネイティブ通知/JSストール監視/初回フレーム待ちの同時発火をまとめる窓。
export const sessionRestartDedupeMs = 3_000;
export const nativeSourceRecoveryDelayMs = 20_000;

// 汎用StreamPlayer(Kick/Twitch/YouTube)の自動復旧間隔。以前は一律「45秒に1回」で、
// 一度失敗すると次の復旧まで最大45秒止まったままだった。初回は即(1.5秒)、失敗が
// 続くほど間隔を広げる。障害イベントは捨てず、予約済みでなければ必ず1回は実行する。
const autoReloadBackoffScheduleMs = [1_500, 4_000, 10_000, 20_000, 40_000];

export function autoReloadBackoffMs(attempt: number): number {
  const normalized = Math.max(0, Math.floor(Number.isFinite(attempt) ? attempt : 0));
  return autoReloadBackoffScheduleMs[Math.min(normalized, autoReloadBackoffScheduleMs.length - 1)];
}

// 直前の自動復旧からこれだけ経っていれば「しばらく安定していた」とみなし、
// 次の障害は初回扱い(最短間隔)で復旧する。
export const autoReloadAttemptResetMs = 90_000;

export function nextAutoReloadAttempt(attempt: number, nowMs: number, lastReloadAtMs: number): number {
  return nowMs - lastReloadAtMs >= autoReloadAttemptResetMs ? 0 : attempt;
}

// Twitch/Kick がエラー/Webフォールバックへ落ちたまま回線が復帰しても、native HLS
// へ戻す者がいない(iOSは再取得ラダーが再接続する)。YouTubeの静かな再解決と同じ
// 方式で回復対象かを判定する。
export function shouldRecoverNativeSource(platform: string, sourceKind: string | null): boolean {
  return (platform === 'twitch' || platform === 'kick') && sourceKind !== null && sourceKind !== 'native';
}

const retryDelaysMs = [1_000, 2_000, 5_000, 10_000, 20_000, 30_000];

export function sessionRetryDelayMs(attempt: number): number {
  const normalized = Math.max(1, Math.floor(Number.isFinite(attempt) ? attempt : 1));
  return retryDelaysMs[Math.min(normalized - 1, retryDelaysMs.length - 1)];
}

export function shouldUseSessionFallback(attempt: number): boolean {
  return Math.max(0, Math.floor(Number.isFinite(attempt) ? attempt : 0)) >= 3;
}

export function shouldRenderNativeSession(nativeReady: boolean, useWebFallback: boolean): boolean {
  return nativeReady && !useWebFallback;
}

export function shouldFallbackForMissingNativeFrame(nativeFrameReady: boolean, elapsedMs: number): boolean {
  return !nativeFrameReady && elapsedMs >= nativeFirstFrameTimeoutMs;
}

export function shouldRestartSessionOnAppState(previous: string | null, next: string): boolean {
  return (previous === 'background' || previous === 'inactive') && next === 'active';
}

export function shouldReloadOnViewActivation(previouslyActive: boolean, active: boolean): boolean {
  return !previouslyActive && active;
}

export type PlayerHealth = 'unknown' | 'healthy' | 'broken';

// タブ復帰時、以前は全セルを無条件に再解決・再マウントしていた(健全なネイティブ再生
// まで黒画面から作り直し)。ネイティブは surface 再バインド(Kotlin側)があるため、
// 直近イベントが健全なセルはそのまま継続してよい。健全と確認できないもの
// (イベント未受信/エラー後/Web系ソース)だけを従来どおり再読込する。
export function shouldReloadCellOnViewActivation(sourceKind: string | null, health: PlayerHealth): boolean {
  if (sourceKind !== 'native') {
    return true;
  }
  return health !== 'healthy';
}

// Twitch/Kick の静かな再解決(オフライン配信では成功しない)を固定20秒間隔で無期限に
// 回さない。失敗が続くほど間隔を倍々で広げ、上限5分で打ち止めにする(成功や配信
// 切替でattemptは0に戻る)。
export const nativeSourceRecoveryMaxDelayMs = 300_000;

export function nativeSourceRecoveryDelayForAttempt(attempt: number): number {
  const normalized = Math.max(0, Math.floor(Number.isFinite(attempt) ? attempt : 0));
  const delay = nativeSourceRecoveryDelayMs * 2 ** Math.min(normalized, 10);
  return Math.min(delay, nativeSourceRecoveryMaxDelayMs);
}

// YouTube の native HLS 昇格再試行: 初回数回は素早く、以降はゆっくり、長期戦は
// さらに間隔を空ける(YouTubeへの負荷抑制)。iframe優先設定時は昇格自体が無意味
// なので呼び出し側でループを止めること。
export function youtubeUpgradeDelayForAttempt(attempt: number): number {
  const normalized = Math.max(0, Math.floor(Number.isFinite(attempt) ? attempt : 0));
  if (normalized < 3) {
    return 6_000;
  }
  if (normalized < 8) {
    return 20_000;
  }
  return 60_000;
}
