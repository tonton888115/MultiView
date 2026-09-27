import React from 'react';
import TestRenderer, {act} from 'react-test-renderer';
import {DeviceEventEmitter, NativeModules} from 'react-native';
import * as network from '../network';

// ネイティブの回線監視モジュールを差し替える(初回問い合わせは wifi を返す)。
(NativeModules as any).NetworkInfo = {
  getConnectionType: jest.fn(() => Promise.resolve('wifi')),
  addListener: jest.fn(),
  removeListeners: jest.fn(),
};

async function flushPromises() {
  await act(async () => {
    await Promise.resolve();
  });
}

describe('network state for playback recovery', () => {
  // 監視開始前(起動直後)の検証なので最初に実行する。
  it('does not treat the unknown startup state as offline', () => {
    expect(network.isNetworkKnownOffline()).toBe(false);
  });

  it('keeps the last connected type for quality while offline and signals restore once', async () => {
    const seen: {type: string; quality: string}[] = [];
    const restored = jest.fn();
    function Probe() {
      const type = network.useNetworkType();
      const quality = network.useQualityNetworkType();
      seen.push({type, quality});
      return null;
    }
    let renderer: TestRenderer.ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(React.createElement(Probe));
    });
    const unsubscribe = network.onNetworkRestored(restored);
    await flushPromises();
    expect(seen[seen.length - 1]).toEqual({type: 'wifi', quality: 'wifi'});
    expect(network.isNetworkKnownOffline()).toBe(false);

    act(() => {
      DeviceEventEmitter.emit('networkChanged', 'none');
    });
    expect(network.isNetworkKnownOffline()).toBe(true);
    // 瞬断で画質(=セッションキー)が揺れないよう、画質用は直前の回線種別を保つ。
    expect(seen[seen.length - 1]).toEqual({type: 'none', quality: 'wifi'});
    expect(restored).not.toHaveBeenCalled();

    act(() => {
      DeviceEventEmitter.emit('networkChanged', 'cellular');
    });
    expect(network.isNetworkKnownOffline()).toBe(false);
    expect(seen[seen.length - 1]).toEqual({type: 'cellular', quality: 'cellular'});
    expect(restored).toHaveBeenCalledTimes(1);

    // 接続中の回線切替(wifi↔cellular)は「復帰」ではない。
    act(() => {
      DeviceEventEmitter.emit('networkChanged', 'wifi');
    });
    expect(restored).toHaveBeenCalledTimes(1);

    unsubscribe();
    act(() => renderer!.unmount());
  });
});
