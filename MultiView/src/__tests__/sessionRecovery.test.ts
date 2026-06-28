import {
  playerStallTimeoutMs,
  sessionConnectTimeoutMs,
  sessionRetryDelayMs,
  shouldRenderNativeSession,
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

  it('times out, falls back temporarily, and continues retrying instead of getting stuck', () => {
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
    expect(latest?.useWebFallback).toBe(false);
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
