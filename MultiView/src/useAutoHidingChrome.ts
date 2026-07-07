import {useCallback, useEffect, useRef, useState} from 'react';

export const chromeAutoHideDelayMs = 2400;

export function useAutoHidingChrome(resetKey: unknown) {
  const [visible, setVisible] = useState(true);
  const hideTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const clearHideTimer = useCallback(() => {
    if (hideTimerRef.current) {
      clearTimeout(hideTimerRef.current);
      hideTimerRef.current = null;
    }
  }, []);

  const show = useCallback(() => {
    clearHideTimer();
    setVisible(true);
    hideTimerRef.current = setTimeout(() => {
      hideTimerRef.current = null;
      setVisible(false);
    }, chromeAutoHideDelayMs);
  }, [clearHideTimer]);

  useEffect(() => {
    show();
    return clearHideTimer;
  }, [clearHideTimer, resetKey, show]);

  return {chromeVisible: visible, showChrome: show};
}
