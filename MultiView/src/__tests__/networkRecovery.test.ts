import React, {useEffect} from 'react';
import TestRenderer, {act} from 'react-test-renderer';

// 回線状態を試験側から切り替えられるようにする(実モジュールはネイティブ監視を使う)。
const mockNetwork = {
  offline: false,
  restoreListeners: new Set<() => void>(),
};

jest.mock('../network', () => ({
  isNetworkKnownOffline: () => mockNetwork.offline,
  onNetworkRestored: (listener: () => void) => {
    mockNetwork.restoreListeners.add(listener);
    return () => {
      mockNetwork.restoreListeners.delete(listener);
    };
  },
}));

import {useRecoveringNativeSession} from '../useRecoveringNativeSession';

type Recovery = ReturnType<typeof useRecoveringNativeSession>;

function RecoveryHarness({report}: {report: (value: Recovery) => void}) {
  const recovery = useRecoveringNativeSession('network-test');
  useEffect(() => {
    report(recovery);
  }, [recovery, report]);
  return null;
}

function restoreNetwork() {
  mockNetwork.offline = false;
  mockNetwork.restoreListeners.forEach(listener => listener());
}

describe('network-aware native session recovery', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    mockNetwork.offline = false;
    mockNetwork.restoreListeners.clear();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('does not burn retries into the web fallback while the device is offline', () => {
    let latest: Recovery | undefined;
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {report: value => { latest = value; }}));
    });
    mockNetwork.offline = true;
    act(() => {
      for (let i = 0; i < 5; i += 1) {
        latest!.handlePlayerStatus('error', 'stall', false);
        latest!.scheduleReconnect();
        jest.advanceTimersByTime(60_000);
      }
    });
    // 回線断中は作り直しも公式Webフォールバックも起こさない(復帰を待つ)。
    expect(latest?.sessionReloadTick).toBe(0);
    expect(latest?.useWebFallback).toBe(false);
    act(() => renderer!.unmount());
  });

  it('restarts immediately with a fresh retry budget when the network comes back', () => {
    let latest: Recovery | undefined;
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {report: value => { latest = value; }}));
    });
    mockNetwork.offline = true;
    act(() => {
      latest!.handlePlayerStatus('error', 'stall', false);
    });
    expect(latest?.sessionReloadTick).toBe(0);
    act(() => {
      restoreNetwork();
    });
    expect(latest?.sessionReloadTick).toBe(1);
    expect(latest?.useWebFallback).toBe(false);
    act(() => renderer!.unmount());
  });

  it('pulls a session out of the temporary web fallback on network restore', () => {
    let latest: Recovery | undefined;
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {report: value => { latest = value; }}));
    });
    act(() => {
      for (let i = 0; i < 3; i += 1) {
        latest!.handlePlayerStatus('error', 'BAD_HTTP_STATUS', false);
        jest.advanceTimersByTime(5_000);
      }
    });
    expect(latest?.useWebFallback).toBe(true);
    const before = latest!.sessionReloadTick;
    act(() => {
      restoreNetwork();
    });
    expect(latest?.useWebFallback).toBe(false);
    expect(latest?.sessionReloadTick).toBe(before + 1);
    act(() => renderer!.unmount());
  });

  it('ignores network restore while the session is healthy', () => {
    let latest: Recovery | undefined;
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(RecoveryHarness, {report: value => { latest = value; }}));
    });
    act(() => {
      latest!.markSessionResolved();
      latest!.handlePlayerStatus('firstFrame', 'rendered', false);
      restoreNetwork();
    });
    expect(latest?.sessionReloadTick).toBe(0);
    act(() => renderer!.unmount());
  });
});
