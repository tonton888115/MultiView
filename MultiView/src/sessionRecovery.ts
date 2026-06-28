export const sessionConnectTimeoutMs = 20_000;
export const playerStallTimeoutMs = 25_000;

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
