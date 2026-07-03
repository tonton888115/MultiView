import {
  autoReloadDelayMs,
  autoReloadFireDelayMs,
  autoReloadMinIntervalMs,
  nativeFirstFrameTimeoutMs,
  playerStallTimeoutMs,
  sessionConnectTimeoutMs,
  sessionRetryDelayMs,
  shouldFallbackForMissingNativeFrame,
  shouldRecoverNativeSource,
  shouldRenderNativeSession,
  shouldRestartSessionOnAppState,
  shouldUseSessionFallback,
} from '../sessionRecovery';
import React, {useEffect} from 'react';
import TestRenderer, {act} from 'react-test-renderer';
import {useRecoveringNativeSession} from '../useRecoveringNativeSession';

type Recovery = ReturnType<typeof useRecoveringNativeSession>;

function RecoveryHarness({
  report,
  identity = 'test-session',
}: {
  report: (value: Recovery) => void;
  identity?: string;
}) {
  const recovery = useRecoveringNativeSession(identity);
  const {sessionReloadTick, startSessionWatchdog} = recovery;
  useEffect(() => {
    report(recovery);
  }, [recovery, report]);
  useEffect(() => {
    startSessionWatchdog();
  }, [sessionReloadTick, startSessionWatchdog]);
  return null;
}

describe('native session recovery policy', () => {
  afterEach(() => {
    jest.useRealTimers();
  });

  it('backs off but keeps retrying indefinitely', () => {
    expect([1, 2, 3, 4, 5, 6, 20].map(sessionRetryDelayMs)).toEqual([
      1_000,
      2_000,
      5_000,
      10_000,
      20_000,
      30_000,
      30_000,
    ]);
  });

  it('uses web fallback temporarily while native retries continue', () => {
    expect(shouldUseSessionFallback(2)).toBe(false);
    expect(shouldUseSessionFallback(3)).toBe(true);
    expect(shouldUseSessionFallback(30)).toBe(true);
    expect(sessionConnectTimeoutMs).toBeLessThan(playerStallTimeoutMs);
  });

  it('renders fallback even when a stale native HLS URL still exists', () => {
    expect(shouldRenderNativeSession(true, false)).toBe(true);
    expect(shouldRenderNativeSession(true, true)).toBe(false);
    expect(shouldRenderNativeSession(false, false)).toBe(false);
  });

  it('falls back when native playback never renders a first video frame', () => {
    expect(shouldFallbackForMissingNativeFrame(false, nativeFirstFrameTimeoutMs - 1)).toBe(false);
    expect(shouldFallbackForMissingNativeFrame(false, nativeFirstFrameTimeoutMs)).toBe(true);
    expect(shouldFallbackForMissingNativeFrame(true, nativeFirstFrameTimeoutMs * 2)).toBe(false);
  });

  it('defers a debounced auto reload instead of dropping it', () => {
    // 初回(または45秒以上経過後)は最短ディレイで発火する。
    expect(autoReloadDelayMs(100_000, 0)).toBe(autoReloadFireDelayMs);
    expect(autoReloadDelayMs(100_000, 100_000 - autoReloadMinIntervalMs)).toBe(autoReloadFireDelayMs);
    // 45秒窓の内側では「捨てる」のではなく窓明けまで繰り延べる。
    expect(autoReloadDelayMs(100_000, 90_000)).toBe(autoReloadMinIntervalMs - 10_000);
    expect(autoReloadDelayMs(100_000, 99_000)).toBe(autoReloadMinIntervalMs - 1_000);
    // 直後の連続発火でも最低ディレイは確保する。
    expect(autoReloadDelayMs(100_000, 100_000)).toBe(autoReloadMinIntervalMs);
  });

  it('recovers Twitch/Kick from non-native sources but leaves YouTube to its own upgrade loop', () => {
    expect(shouldRecoverNativeSource('twitch', 'error')).toBe(true);
    expect(shouldRecoverNativeSource('twitch', 'web')).toBe(true);
    expect(shouldRecoverNativeSource('kick', 'error')).toBe(true);
    expect(shouldRecoverNativeSource('twitch', 'native')).toBe(false);
    expect(shouldRecoverNativeSource('kick', 'native')).toBe(false);
    expect(shouldRecoverNativeSource('twitch', null)).toBe(false);
    expect(shouldRecoverNativeSource('youtube', 'error')).toBe(false);
    expect(shouldRecoverNativeSource('youtube', 'youtube-iframe')).toBe(false);
    expect(shouldRecoverNativeSource('niconico', 'web')).toBe(false);
    expect(shouldRecoverNativeSource('twitcasting', 'web')).toBe(false);
  });

  it('restarts a native session only when the app returns from background', () => {
    expect(shouldRestartSessionOnAppState('background', 'active')).toBe(true);
    expect(shouldRestartSessionOnAppState('inactive', 'active')).toBe(true);
    expect(shouldRestartSessionOnAppState('active', 'active')).toBe(false);
    expect(shouldRestartSessionOnAppState('active', 'background')).toBe(false);
    expect(shouldRestartSessionOnAppState(null, 'active')).toBe(false);
    expect(shouldRestartSessionOnAppState('unknown', 'active')).toBe(false);
  });

  it('times out, keeps fallback visible, and continues retrying instead of getting stuck', () => {
    jest.useFakeTimers();
    let latest: Recovery | undefined;
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {
        report: value => { latest = value; },
      }));
    });

    act(() => { jest.advanceTimersByTime(sessionConnectTimeoutMs + 1_000); });
    expect(latest?.sessionReloadTick).toBe(1);
    act(() => { jest.advanceTimersByTime(sessionConnectTimeoutMs + 2_000); });
    expect(latest?.sessionReloadTick).toBe(2);
    act(() => { jest.advanceTimersByTime(sessionConnectTimeoutMs); });
    expect(latest?.useWebFallback).toBe(true);
    act(() => { jest.advanceTimersByTime(5_000); });
    expect(latest?.useWebFallback).toBe(true);
    expect(latest?.sessionReloadTick).toBe(3);
    act(() => { jest.advanceTimersByTime(sessionConnectTimeoutMs + 10_000); });
    expect(latest?.sessionReloadTick).toBe(4);

    act(() => renderer!.unmount());
  });

  it('recovers from a player stall after the session itself resolved', () => {
    jest.useFakeTimers();
    let latest: Recovery | undefined;
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {
        report: value => { latest = value; },
      }));
    });
    act(() => {
      latest!.markSessionResolved();
      latest!.handlePlayerStatus('status', 'buffering', false);
      jest.advanceTimersByTime(playerStallTimeoutMs + 1_000);
    });
    expect(latest?.sessionReloadTick).toBe(1);
    act(() => renderer!.unmount());
  });

  it('treats a bare idle status as a stall instead of disarming recovery', () => {
    // 致命的エラー後の ExoPlayer は IDLE で停止する。error イベント自体が失われて
    // 'idle' だけが届いた場合でも、復旧が予約されなければ永久凍結してしまう。
    jest.useFakeTimers();
    let latest: Recovery | undefined;
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {
        report: value => { latest = value; },
      }));
    });
    act(() => {
      latest!.markSessionResolved();
      latest!.handlePlayerStatus('status', 'idle', false);
      jest.advanceTimersByTime(playerStallTimeoutMs + 1_000);
    });
    expect(latest?.sessionReloadTick).toBe(1);
    act(() => renderer!.unmount());
  });

  it('keeps the stall watchdog armed when buffering is followed by a non-user paused event', () => {
    jest.useFakeTimers();
    let latest: Recovery | undefined;
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {
        report: value => { latest = value; },
      }));
    });
    act(() => {
      latest!.markSessionResolved();
      latest!.handlePlayerStatus('status', 'buffering', false);
      jest.advanceTimersByTime(playerStallTimeoutMs / 2);
      // ExoPlayer normally reports isPlaying=false while it is buffering. That is
      // not a user pause and must not disarm or restart the original stall timer.
      latest!.handlePlayerStatus('status', 'paused', false);
      jest.advanceTimersByTime(playerStallTimeoutMs / 2);
    });
    expect(latest?.sessionReloadTick).toBe(1);
    act(() => renderer!.unmount());
  });

  it('disarms the stall watchdog while the user intentionally pauses playback', () => {
    jest.useFakeTimers();
    let latest: Recovery | undefined;
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {
        report: value => { latest = value; },
      }));
    });
    act(() => {
      latest!.markSessionResolved();
      latest!.handlePlayerStatus('status', 'buffering', false);
      latest!.handlePlayerStatus('status', 'paused', true);
      jest.advanceTimersByTime(playerStallTimeoutMs + 1_000);
    });
    expect(latest?.sessionReloadTick).toBe(0);
    act(() => renderer!.unmount());
  });

  it('re-arms after a stall timeout is coalesced with an already pending reconnect', () => {
    jest.useFakeTimers();
    let latest: Recovery | undefined;
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {
        report: value => { latest = value; },
      }));
    });
    act(() => {
      latest!.markSessionResolved();
      latest!.handlePlayerStatus('status', 'buffering', false);
      jest.advanceTimersByTime(playerStallTimeoutMs - 500);
      latest!.scheduleReconnect();
      jest.advanceTimersByTime(500);
    });
    expect(latest?.sessionReloadTick).toBe(0);
    act(() => {
      jest.advanceTimersByTime(500);
      latest!.markSessionResolved();
      latest!.handlePlayerStatus('status', 'buffering', false);
      jest.advanceTimersByTime(playerStallTimeoutMs);
    });
    expect(latest?.sessionReloadTick).toBe(2);
    act(() => renderer!.unmount());
  });

  it('invalidates a failed native player session immediately before stale streams can cancel recovery', () => {
    jest.useFakeTimers();
    let latest: Recovery | undefined;
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {
        report: value => { latest = value; },
      }));
    });
    act(() => {
      latest!.markSessionResolved();
      latest!.handlePlayerStatus('error', 'BAD_DECRYPT', false);
    });
    expect(latest?.sessionReloadTick).toBe(1);
    expect(latest?.useWebFallback).toBe(false);
    act(() => renderer!.unmount());
  });

  it('lets an explicit foreground restart preempt an older backoff timer', () => {
    jest.useFakeTimers();
    let latest: Recovery | undefined;
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {
        report: value => { latest = value; },
      }));
    });
    act(() => {
      latest!.scheduleReconnect();
      jest.advanceTimersByTime(500);
      latest!.restartSessionNow();
    });
    expect(latest?.sessionReloadTick).toBe(1);
    act(() => {
      // The cancelled first-attempt timer must not remount the new session.
      jest.advanceTimersByTime(500);
    });
    expect(latest?.sessionReloadTick).toBe(1);
    act(() => renderer!.unmount());
  });

  it('does not reset the retry streak until native playback actually renders', () => {
    jest.useFakeTimers();
    let latest: Recovery | undefined;
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {
        report: value => { latest = value; },
      }));
    });
    act(() => {
      latest!.markSessionResolved();
      latest!.handlePlayerStatus('error', 'BAD_DECRYPT', false);
    });
    expect(latest?.sessionReloadTick).toBe(1);
    expect(latest?.useWebFallback).toBe(false);
    act(() => {
      latest!.markSessionResolved();
      latest!.handlePlayerStatus('error', 'BAD_DECRYPT', false);
    });
    expect(latest?.sessionReloadTick).toBe(2);
    expect(latest?.useWebFallback).toBe(false);
    act(() => {
      latest!.markSessionResolved();
      latest!.handlePlayerStatus('error', 'BAD_DECRYPT', false);
    });
    expect(latest?.sessionReloadTick).toBe(3);
    expect(latest?.useWebFallback).toBe(true);
    expect(latest?.useWebFallback).toBe(true);
    expect(latest?.sessionReloadTick).toBe(3);
    act(() => renderer!.unmount());
  });

  it('cancels pending recovery on playing and resets the retry backoff', () => {
    jest.useFakeTimers();
    let latest: Recovery | undefined;
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {
        report: value => { latest = value; },
      }));
    });
    act(() => {
      latest!.scheduleReconnect();
      jest.advanceTimersByTime(1_000);
      latest!.handlePlayerStatus('status', 'playing', false);
      latest!.scheduleReconnect();
      jest.advanceTimersByTime(1_000);
    });
    expect(latest?.sessionReloadTick).toBe(2);
    act(() => renderer!.unmount());
  });

  it('cancels the connect watchdog once a session resolves', () => {
    jest.useFakeTimers();
    let latest: Recovery | undefined;
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {
        report: value => { latest = value; },
      }));
    });
    act(() => {
      latest!.markSessionResolved();
      jest.advanceTimersByTime(sessionConnectTimeoutMs * 2);
    });
    expect(latest?.sessionReloadTick).toBe(0);
    act(() => renderer!.unmount());
    expect(jest.getTimerCount()).toBe(0);
  });

  it('resets timers and fallback state when the stream identity changes', () => {
    jest.useFakeTimers();
    let latest: Recovery | undefined;
    const report = (value: Recovery) => { latest = value; };
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {report, identity: 'one'}));
    });
    act(() => {
      latest!.scheduleReconnect();
      jest.advanceTimersByTime(1_000);
      latest!.scheduleReconnect();
      jest.advanceTimersByTime(2_000);
      latest!.scheduleReconnect();
    });
    expect(latest?.useWebFallback).toBe(true);
    act(() => {
      renderer!.update(React.createElement(RecoveryHarness, {report, identity: 'two'}));
    });
    expect(latest?.useWebFallback).toBe(false);
    expect(latest?.sessionReloadTick).toBe(3);
    act(() => renderer!.unmount());
    expect(jest.getTimerCount()).toBe(0);
  });
});
