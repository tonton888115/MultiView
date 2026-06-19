import {useEffect, useState} from 'react';
import {NativeEventEmitter, NativeModules} from 'react-native';
import type {NetworkType} from './types';

export type {NetworkType} from './types';

type NativeNetworkInfoModule = {
  getConnectionType?: () => Promise<unknown>;
  addListener?: (eventName: string) => void;
  removeListeners?: (count: number) => void;
};

const pollIntervalMs = 8000;
const listeners = new Set<(type: NetworkType) => void>();
let currentNetworkType: NetworkType = 'none';
let nativeSubscription: {remove: () => void} | undefined;
let pollTimer: ReturnType<typeof setInterval> | undefined;

function nativeNetworkInfo(): NativeNetworkInfoModule | undefined {
  try {
    return (NativeModules as {NetworkInfo?: NativeNetworkInfoModule}).NetworkInfo;
  } catch {
    return undefined;
  }
}

function parseNetworkType(value: unknown): NetworkType | null {
  return value === 'wifi' || value === 'cellular' || value === 'other' || value === 'none' ? value : null;
}

export function isCellular(type: NetworkType): boolean {
  return type === 'cellular';
}

function applyType(value: unknown) {
  const next = parseNetworkType(value);
  if (!next || next === currentNetworkType) {
    return;
  }
  currentNetworkType = next;
  listeners.forEach(listener => listener(next));
}

function pollConnectionType() {
  try {
    const request = nativeNetworkInfo()?.getConnectionType?.();
    request?.then(applyType).catch(() => {});
  } catch {
  }
}

function startMonitoring() {
  if (pollTimer) {
    return;
  }

  pollConnectionType();

  try {
    const module = nativeNetworkInfo();
    if (module) {
      nativeSubscription = new NativeEventEmitter(module as any).addListener('networkChanged', applyType);
    }
  } catch {
    nativeSubscription = undefined;
  }

  pollTimer = setInterval(pollConnectionType, pollIntervalMs);
}

function stopMonitoring() {
  if (nativeSubscription) {
    try {
      nativeSubscription.remove();
    } catch {
    }
    nativeSubscription = undefined;
  }
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = undefined;
  }
  currentNetworkType = 'none';
}

export function useNetworkType(): NetworkType {
  const [networkType, setNetworkType] = useState<NetworkType>(() => currentNetworkType);

  useEffect(() => {
    listeners.add(setNetworkType);
    startMonitoring();
    setNetworkType(currentNetworkType);
    return () => {
      listeners.delete(setNetworkType);
      if (listeners.size === 0) {
        stopMonitoring();
      }
    };
  }, []);

  return networkType;
}
