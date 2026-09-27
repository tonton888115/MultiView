import {
  autoReloadAttemptResetMs,
  autoReloadBackoffMs,
  nativeFirstFrameTimeoutMs,
  nextAutoReloadAttempt,
  nativeSourceRecoveryDelayForAttempt,
  nativeSourceRecoveryMaxDelayMs,
  playerStallTimeoutMs,
  sessionRestartDedupeMs,
  sessionConnectTimeoutMs,
  sessionRetryDelayMs,
  shouldFallbackForMissingNativeFrame,
  shouldRecoverNativeSource,
  shouldReloadCellOnViewActivation,
  shouldRenderNativeSession,
  shouldRestartSessionOnAppState,
  shouldUseSessionFallback,
  youtubeUpgradeDelayForAttempt,
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

  it('recovers the first failure quickly and backs off repeated failures', () => {
    // 初回は1.5秒で復旧(以前は45秒窓で最大45秒止まったままだった)。
    expect(autoReloadBackoffMs(0)).toBe(1_500);
    expect(autoReloadBackoffMs(1)).toBe(4_000);
    expect(autoReloadBackoffMs(2)).toBe(10_000);
    // 失敗が続いても上限で頭打ちにし、回数が壊れていても安全側に倒す。
    expect(autoReloadBackoffMs(50)).toBe(40_000);
    expect(autoReloadBackoffMs(Number.NaN)).toBe(1_500);
  });

  it('treats a failure after a long stable period as a first failure again', () => {
    expect(nextAutoReloadAttempt(3, 200_000, 200_000 - autoReloadAttemptResetMs)).toBe(0);
    expect(nextAutoReloadAttempt(3, 200_000, 200_000 - autoReloadAttemptResetMs + 1)).toBe(3);
    expect(nextAutoReloadAttempt(0, 200_000, 0)).toBe(0);
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
      // 作り直した次のセッションが改めて失敗する(=別の障害)までには時間が経つ。
      jest.advanceTimersByTime(sessionRestartDedupeMs);
      latest!.markSessionResolved();
      latest!.handlePlayerStatus('error', 'BAD_DECRYPT', false);
    });
    expect(latest?.sessionReloadTick).toBe(2);
    expect(latest?.useWebFallback).toBe(false);
    act(() => {
      jest.advanceTimersByTime(sessionRestartDedupeMs);
      latest!.markSessionResolved();
      latest!.handlePlayerStatus('error', 'BAD_DECRYPT', false);
    });
    expect(latest?.sessionReloadTick).toBe(3);
    expect(latest?.useWebFallback).toBe(true);
    expect(latest?.useWebFallback).toBe(true);
    expect(latest?.sessionReloadTick).toBe(3);
    act(() => renderer!.unmount());
  });

  it('counts simultaneous failure signals for one incident only once', () => {
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
      // ネイティブのストール通知と JS 側の監視が同じ障害で続けて届く。
      latest!.handlePlayerStatus('error', 'stall', false);
      latest!.restartSessionNow();
      latest!.handlePlayerStatus('error', 'stall', false);
    });
    expect(latest?.sessionReloadTick).toBe(1);
    expect(latest?.useWebFallback).toBe(false);
    act(() => renderer!.unmount());
  });

  it('keeps a queued reconnect when a duplicate restart is coalesced', () => {
    jest.useFakeTimers();
    let latest: Recovery | undefined;
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {
        report: value => { latest = value; },
      }));
    });
    act(() => {
      latest!.restartSessionNow();
    });
    expect(latest?.sessionReloadTick).toBe(1);
    act(() => {
      // 作り直した直後のセッションが失敗して再接続を予約し、同じ窓で重複通知が来る。
      latest!.scheduleReconnect();
      latest!.restartSessionNow();
      jest.advanceTimersByTime(sessionRetryDelayMs(2) + 100);
    });
    // 重複通知はまとめても、予約済みの再接続は消えずに実行される。
    expect(latest?.sessionReloadTick).toBe(2);
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

describe('selective reload on view activation', () => {
  it('keeps healthy native cells mounted', () => {
    expect(shouldReloadCellOnViewActivation('native', 'healthy')).toBe(false);
  });

  it('reloads native cells that are broken or unconfirmed', () => {
    expect(shouldReloadCellOnViewActivation('native', 'broken')).toBe(true);
    expect(shouldReloadCellOnViewActivation('native', 'unknown')).toBe(true);
  });

  it('always reloads non-native sources (no health signal)', () => {
    expect(shouldReloadCellOnViewActivation('web', 'healthy')).toBe(true);
    expect(shouldReloadCellOnViewActivation('youtube-iframe', 'healthy')).toBe(true);
    expect(shouldReloadCellOnViewActivation('error', 'unknown')).toBe(true);
    expect(shouldReloadCellOnViewActivation(null, 'unknown')).toBe(true);
  });
});

describe('native source recovery backoff', () => {
  it('starts at the base delay and doubles per failed attempt', () => {
    expect(nativeSourceRecoveryDelayForAttempt(0)).toBe(20_000);
    expect(nativeSourceRecoveryDelayForAttempt(1)).toBe(40_000);
    expect(nativeSourceRecoveryDelayForAttempt(2)).toBe(80_000);
    expect(nativeSourceRecoveryDelayForAttempt(3)).toBe(160_000);
  });

  it('caps at 5 minutes and tolerates garbage input', () => {
    expect(nativeSourceRecoveryDelayForAttempt(4)).toBe(nativeSourceRecoveryMaxDelayMs);
    expect(nativeSourceRecoveryDelayForAttempt(100)).toBe(nativeSourceRecoveryMaxDelayMs);
    expect(nativeSourceRecoveryDelayForAttempt(Number.NaN)).toBe(20_000);
    expect(nativeSourceRecoveryDelayForAttempt(-5)).toBe(20_000);
  });
});

describe('youtube upgrade retry schedule', () => {
  it('is fast first, then slow, then sparse', () => {
    expect(youtubeUpgradeDelayForAttempt(0)).toBe(6_000);
    expect(youtubeUpgradeDelayForAttempt(2)).toBe(6_000);
    expect(youtubeUpgradeDelayForAttempt(3)).toBe(20_000);
    expect(youtubeUpgradeDelayForAttempt(7)).toBe(20_000);
    expect(youtubeUpgradeDelayForAttempt(8)).toBe(60_000);
    expect(youtubeUpgradeDelayForAttempt(50)).toBe(60_000);
  });
});
