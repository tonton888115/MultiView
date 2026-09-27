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
const restoreListeners = new Set<() => void>();
let currentNetworkType: NetworkType = 'none';
// 初回の問い合わせが返るまでは 'none' でも「未確定」であって「オフライン」ではない。
let networkTypeKnown = false;
// 画質判定用: 直近に接続していた回線種別。瞬断('none')のたびに画質=セッションキーが
// 変わって視聴セッションを作り直さないよう、オフライン中は直前の回線種別を保つ。
let lastConnectedNetworkType: NetworkType = 'none';
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

// タイムアウト付き fetch の共通実装。Promise.race だけの実装はタイムアウト後も
// 裏の fetch(接続)が生き残り、回線断中に復旧サイクルを詰まらせるため、
// AbortController で fetch 自体も必ず中断する。
export async function fetchWithTimeout(url: string, init: RequestInit, timeoutMs: number): Promise<Response> {
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<Response>((_, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new Error(`Request timed out after ${timeoutMs}ms`));
    }, timeoutMs);
  });
  try {
    return await Promise.race([fetch(url, {...init, signal: controller.signal}), timeout]);
  } finally {
    if (timer) {
      clearTimeout(timer);
    }
  }
}

function applyType(value: unknown) {
  const next = parseNetworkType(value);
  if (!next) {
    return;
  }
  const wasOffline = networkTypeKnown && currentNetworkType === 'none';
  networkTypeKnown = true;
  if (next === currentNetworkType) {
    return;
  }
  currentNetworkType = next;
  if (next !== 'none') {
    lastConnectedNetworkType = next;
  }
  listeners.forEach(listener => listener(next));
  if (wasOffline && next !== 'none') {
    // 回線復帰: 待機中/失敗中のプレイヤーをバックオフ待ちにせず即再接続させる。
    restoreListeners.forEach(listener => {
      try {
        listener();
      } catch {
        // 1つの購読者の失敗で他の復帰処理を止めない。
      }
    });
  }
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
  networkTypeKnown = false;
}

// 端末がオフラインだと確定している時だけ true(起動直後の未確定状態は false)。
// 復旧処理はこの間リトライ回数を消費せず、回線復帰(onNetworkRestored)を待つ。
export function isNetworkKnownOffline(): boolean {
  return networkTypeKnown && currentNetworkType === 'none';
}

export function onNetworkRestored(listener: () => void): () => void {
  restoreListeners.add(listener);
  return () => {
    restoreListeners.delete(listener);
  };
}

function useNetworkListener<T>(select: () => T): T {
  const [value, setValue] = useState<T>(select);

  useEffect(() => {
    const listener = () => setValue(select());
    listeners.add(listener);
    startMonitoring();
    listener();
    return () => {
      listeners.delete(listener);
      if (listeners.size === 0) {
        stopMonitoring();
      }
    };
    // select は呼び出し側で固定の関数を渡す。
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return value;
}

// 画質(エコノミー判定/セッションキー)用の回線種別。オフライン中は直前の回線種別を返す。
export function useQualityNetworkType(): NetworkType {
  return useNetworkListener(() => lastConnectedNetworkType);
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
