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

  const scheduleReconnect = useCallback(() => {
    if (!mountedRef.current || reconnectTimerRef.current) {
      return;
    }
    clearWatchdogs();
    const attempt = retryCountRef.current + 1;
    retryCountRef.current = attempt;
    setUseWebFallback(shouldUseSessionFallback(attempt));
    reconnectTimerRef.current = setTimeout(() => {
      reconnectTimerRef.current = null;
      if (!mountedRef.current) {
        return;
      }
      setUseWebFallback(false);
      setSessionReloadTick(tick => tick + 1);
    }, sessionRetryDelayMs(attempt));
  }, [clearWatchdogs]);

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
      scheduleReconnect();
      return;
    }
    if (message === 'playing') {
      clearWatchdogs();
      clearTimer(reconnectTimerRef);
      retryCountRef.current = 0;
      setUseWebFallback(false);
      return;
    }
    if (!paused && (message === 'buffering' || message === 'loading')) {
      if (!stallWatchdogRef.current) {
        stallWatchdogRef.current = setTimeout(scheduleReconnect, playerStallTimeoutMs);
      }
      return;
    }
    clearTimer(stallWatchdogRef);
  }, [clearTimer, clearWatchdogs, scheduleReconnect]);

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
    startSessionWatchdog,
    markSessionResolved,
    handlePlayerStatus,
  };
}
