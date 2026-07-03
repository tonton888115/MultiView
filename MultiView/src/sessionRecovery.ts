export const sessionConnectTimeoutMs = 20_000;
export const playerStallTimeoutMs = 25_000;
export const nativeFirstFrameTimeoutMs = 12_000;
export const autoReloadMinIntervalMs = 45_000;
export const autoReloadFireDelayMs = 1_500;
export const nativeSourceRecoveryDelayMs = 20_000;

// 汎用StreamPlayerの自動リロードは45秒に1回へ間引くが、間引いた障害イベントを
// 捨てると致命的エラー(STATE_IDLE)後は誰も再試行せず永久凍結する。次に発火
// できる時刻まで遅延して、予約済みでなければ必ず1回は実行する。
export function autoReloadDelayMs(nowMs: number, lastReloadAtMs: number): number {
  return Math.max(autoReloadFireDelayMs, lastReloadAtMs + autoReloadMinIntervalMs - nowMs);
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
