import {useCallback, useEffect, useRef, useState, type MutableRefObject} from 'react';
import {
  playerStallTimeoutMs,
  sessionConnectTimeoutMs,
  sessionRetryDelayMs,
  shouldUseSessionFallback,
} from './sessionRecovery';

export function useRecoveringNativeSession(identityKey: string) {
  const [sessionReloadTick, setSessionReloadTick] = useState(0);
  const [useWebFallback, setUseWebFallback] = useState(false);
  const identityRef = useRef(identityKey);
  const retryCountRef = useRef(0);
  const reconnectTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const connectWatchdogRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const stallWatchdogRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const mountedRef = useRef(true);

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
  }, [clearTimer, clearWatchdogs]);

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
    setUseWebFallback(false);
  }, [clearTimer]);

  const handlePlayerStatus = useCallback((type: string, message: string, paused: boolean) => {
    if (type === 'error' || message === 'ended') {
      restartSessionNow();
      return;
    }
    if (type === 'firstFrame' || message === 'playing') {
      clearWatchdogs();
      clearTimer(reconnectTimerRef);
      retryCountRef.current = 0;
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
  }, [clearTimer, clearWatchdogs, restartSessionNow]);

  useEffect(() => {
    mountedRef.current = true;
    if (identityRef.current !== identityKey) {
      identityRef.current = identityKey;
      clearWatchdogs();
      clearTimer(reconnectTimerRef);
      retryCountRef.current = 0;
      setUseWebFallback(false);
      setSessionReloadTick(tick => tick + 1);
    }
    return () => {
      mountedRef.current = false;
      clearWatchdogs();
      clearTimer(reconnectTimerRef);
    };
  }, [clearTimer, clearWatchdogs, identityKey]);

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
