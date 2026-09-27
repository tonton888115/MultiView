import {useCallback, useEffect, useRef, useState, type MutableRefObject} from 'react';
import {isNetworkKnownOffline, onNetworkRestored} from './network';
import {
  playerStallTimeoutMs,
  sessionConnectTimeoutMs,
  sessionRestartDedupeMs,
  sessionRetryDelayMs,
  shouldUseSessionFallback,
} from './sessionRecovery';

export function useRecoveringNativeSession(identityKey: string) {
  const [sessionReloadTick, setSessionReloadTick] = useState(0);
  const [useWebFallback, setUseWebFallbackState] = useState(false);
  const useWebFallbackRef = useRef(false);
  const identityRef = useRef(identityKey);
  const retryCountRef = useRef(0);
  const reconnectTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const connectWatchdogRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const stallWatchdogRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // 回線断中に失敗したセッション。再試行は必ず失敗して回数だけ消費し、3回で公式Web
  // フォールバックへ落ちてしまうため、回線復帰(onNetworkRestored)まで待って即再接続する。
  const waitingForNetworkRef = useRef(false);
  // ネイティブのストール通知・JS側ストール監視・初回フレーム待ちが同時に発火しても、
  // 1回の障害で2回作り直さない(試行回数を二重に消費しない)。
  const lastImmediateRestartAtRef = useRef(0);
  const mountedRef = useRef(true);

  const setUseWebFallback = useCallback((next: boolean) => {
    useWebFallbackRef.current = next;
    setUseWebFallbackState(next);
  }, []);

  const clearTimer = useCallback((ref: MutableRefObject<ReturnType<typeof setTimeout> | null>) => {
    if (ref.current) {
      clearTimeout(ref.current);
      ref.current = null;
    }
  }, []);

  const clearWatchdogs = useCallback(() => {
    clearTimer(connectWatchdogRef);
    clearTimer(stallWatchdogRef);
  }, [clearTimer]);

  const beginReconnect = useCallback((immediate: boolean) => {
    if (!mountedRef.current) {
      return;
    }
    if (isNetworkKnownOffline()) {
      clearWatchdogs();
      clearTimer(reconnectTimerRef);
      waitingForNetworkRef.current = true;
      return;
    }
    if (immediate) {
      // 同じ障害の重複通知はまとめる。予約済みの再接続は消さずに残す(ここで消してから
      // 抜けると、再接続が1つも無いまま止まる)。
      const now = Date.now();
      if (now - lastImmediateRestartAtRef.current < sessionRestartDedupeMs) {
        return;
      }
      lastImmediateRestartAtRef.current = now;
    }
    if (reconnectTimerRef.current) {
      if (!immediate) {
        return;
      }
      // Foreground recovery and a native-player failure are explicit
      // invalidations. Do not leave the unusable session mounted behind an
      // older exponential-backoff timer (which can be as long as 30s).
      clearTimer(reconnectTimerRef);
    }
    clearWatchdogs();
    const attempt = retryCountRef.current + 1;
    retryCountRef.current = attempt;
    const fallback = shouldUseSessionFallback(attempt);
    setUseWebFallback(fallback);
    if (immediate) {
      setSessionReloadTick(tick => tick + 1);
      return;
    }
    reconnectTimerRef.current = setTimeout(() => {
      reconnectTimerRef.current = null;
      if (!mountedRef.current) {
        return;
      }
      if (!fallback) {
        setUseWebFallback(false);
      }
      setSessionReloadTick(tick => tick + 1);
    }, sessionRetryDelayMs(attempt));
  }, [clearTimer, clearWatchdogs, setUseWebFallback]);

  const scheduleReconnect = useCallback(() => {
    beginReconnect(false);
  }, [beginReconnect]);

  const restartSessionNow = useCallback(() => {
    beginReconnect(true);
  }, [beginReconnect]);

  const startSessionWatchdog = useCallback(() => {
    clearTimer(connectWatchdogRef);
    connectWatchdogRef.current = setTimeout(scheduleReconnect, sessionConnectTimeoutMs);
  }, [clearTimer, scheduleReconnect]);

  const markSessionResolved = useCallback(() => {
    clearTimer(connectWatchdogRef);
    clearTimer(reconnectTimerRef);
    waitingForNetworkRef.current = false;
    setUseWebFallback(false);
  }, [clearTimer, setUseWebFallback]);

  const handlePlayerStatus = useCallback((type: string, message: string, paused: boolean) => {
    if (type === 'error' || message === 'ended') {
      restartSessionNow();
      return;
    }
    if (type === 'firstFrame' || message === 'playing') {
      clearWatchdogs();
      clearTimer(reconnectTimerRef);
      retryCountRef.current = 0;
      waitingForNetworkRef.current = false;
      setUseWebFallback(false);
      return;
    }
    if (paused) {
      clearTimer(stallWatchdogRef);
      return;
    }
    // 'idle' は致命的エラー後の停止状態でもあり、error イベント自体が(バックグラウンドや
    // dispatcher 不在で)失われた場合は 'idle' が唯一の信号になる。解除ではなく監視する。
    if (message === 'buffering' || message === 'loading' || message === 'paused' || message === 'ready' || message === 'idle') {
      if (!stallWatchdogRef.current) {
        stallWatchdogRef.current = setTimeout(() => {
          // A fired timeout must not remain as a truthy stale handle when an
          // existing reconnect timer makes beginReconnect coalesce this event.
          stallWatchdogRef.current = null;
          restartSessionNow();
        }, playerStallTimeoutMs);
      }
      return;
    }
    clearTimer(stallWatchdogRef);
  }, [clearTimer, clearWatchdogs, restartSessionNow, setUseWebFallback]);

  // 回線復帰: 待機中・再試行待ち・一時Webフォールバック中のセッションは、バックオフや
  // フォールバックのまま放置せず、試行回数をリセットして即ネイティブで貼り直す。
  useEffect(() => onNetworkRestored(() => {
    if (!mountedRef.current) {
      return;
    }
    if (!waitingForNetworkRef.current && !reconnectTimerRef.current && !useWebFallbackRef.current) {
      return;
    }
    waitingForNetworkRef.current = false;
    retryCountRef.current = 0;
    lastImmediateRestartAtRef.current = Date.now();
    clearTimer(reconnectTimerRef);
    clearWatchdogs();
    setUseWebFallback(false);
    setSessionReloadTick(tick => tick + 1);
  }), [clearTimer, clearWatchdogs, setUseWebFallback]);

  useEffect(() => {
    mountedRef.current = true;
    if (identityRef.current !== identityKey) {
      identityRef.current = identityKey;
      clearWatchdogs();
      clearTimer(reconnectTimerRef);
      retryCountRef.current = 0;
      waitingForNetworkRef.current = false;
      setUseWebFallback(false);
      setSessionReloadTick(tick => tick + 1);
    }
    return () => {
      mountedRef.current = false;
      clearWatchdogs();
      clearTimer(reconnectTimerRef);
    };
  }, [clearTimer, clearWatchdogs, identityKey, setUseWebFallback]);

  return {
    sessionReloadTick,
    useWebFallback,
    scheduleReconnect,
    restartSessionNow,
    startSessionWatchdog,
    markSessionResolved,
    handlePlayerStatus,
  };
}
