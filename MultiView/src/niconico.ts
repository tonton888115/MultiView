// iOS NiconicoPlayer.swift の視聴セッション(WebSocket)部分を移植。
// watch ページの data-props から WebSocket URL を取り、startWatching を送って
// HLS の uri と cookie を受け取る。これにより「ニコ生もネイティブ HLS で映像だけ」
// (フル Web ページ＝広告/ポップアップだらけ を脱却) を実現する。
//
// NDGR コメント(弾幕)は別途 messageServer.viewUri から取得する(Phase 3B.3)。ここでは
// 再生用の HLS セッションのみを担当し、失敗時は呼び出し側が Web フォールバックする。

import {mobileUserAgent} from './playback';
import type {AppSettings} from './types';

export type NiconicoStreamInfo = {
  hlsUrl: string;
  cookieHeader?: string;
  // NDGR コメント取得用(後続フェーズで使用)
  viewUri?: string;
};

export type NiconicoCallbacks = {
  onStream: (info: NiconicoStreamInfo) => void;
  onStatus?: (message: string) => void;
  onError: (message: string) => void;
  onEnded?: () => void;
};

export type NiconicoSession = {stop: () => void};

type WatchData = {wsUrl: string; frontendId?: string};

function niconicoQuality(settings: AppSettings): string {
  // iOS: high -> "abr", economy -> "low"
  return settings.wifiQuality === 'economy' ? 'low' : 'abr';
}

export function parseNiconicoWatchData(html: string): WatchData | null {
  const propsRaw =
    matchGroup(html, /<script[^>]+id=["']embedded-data["'][^>]+data-props=["']([^"']+)["']/) ??
    matchGroup(html, /data-props=["']([^"']+)["'][^>]+id=["']embedded-data["']/) ??
    matchGroup(html, /<script[^>]+id=["']initial-state["'][^>]+data-props=["']([^"']+)["']/) ??
    matchGroup(html, /data-props=["']([^"']+)["'][^>]+id=["']initial-state["']/);
  if (!propsRaw) {
    return null;
  }
  let props: any;
  try {
    props = JSON.parse(decodeHTMLEntities(propsRaw));
  } catch {
    return null;
  }
  // 新形式: pageContents.watchInformation.playerParams.wsEndPoint.url
  const wsEndPoint = props?.pageContents?.watchInformation?.playerParams?.wsEndPoint;
  const newUrl = typeof wsEndPoint?.url === 'string' ? wsEndPoint.url : null;
  if (newUrl) {
    const fid = props?.constants?.requestInfo?.frontendId;
    return {wsUrl: newUrl, frontendId: fid != null ? String(fid) : undefined};
  }
  // 旧形式: site.relive.webSocketUrl
  const site = props?.site;
  const wsString: string | undefined =
    site?.relive?.webSocketUrl ?? site?.webSocketUrl ?? site?.websocketUrl;
  if (typeof wsString === 'string' && wsString) {
    const fid = site?.frontendId ?? site?.frontendID;
    return {wsUrl: wsString, frontendId: fid != null ? String(fid) : undefined};
  }
  return null;
}

export function openNiconicoSession(
  programId: string,
  settings: AppSettings,
  cb: NiconicoCallbacks,
): NiconicoSession {
  let stopped = false;
  let socket: WebSocket | undefined;
  let keepSeatTimer: ReturnType<typeof setInterval> | undefined;
  let gotStream = false;
  let pendingViewUri: string | undefined;
  const watchURL = `https://live.nicovideo.jp/watch/${encodeURIComponent(programId.trim())}`;
  const status = (m: string) => cb.onStatus?.(m);

  const cleanup = () => {
    if (keepSeatTimer) {
      clearInterval(keepSeatTimer);
      keepSeatTimer = undefined;
    }
    try {
      socket?.close();
    } catch {
      // ignore
    }
    socket = undefined;
  };

  const fail = (message: string) => {
    if (stopped) {
      return;
    }
    cleanup();
    cb.onError(message);
  };

  const send = (payload: unknown) => {
    try {
      socket?.send(JSON.stringify(payload));
    } catch {
      // ignore transient send failures
    }
  };

  const sendStartWatching = () => {
    send({
      type: 'startWatching',
      data: {
        stream: {
          quality: niconicoQuality(settings),
          protocol: 'hls',
          latency: 'low',
          requireNewStream: true,
          accessRightMethod: 'single_cookie',
          chasePlay: false,
        },
        room: {protocol: 'webSocket', commentable: true},
        reconnect: false,
      },
    });
  };

  const handleText = (text: string) => {
    let json: any;
    try {
      json = JSON.parse(text);
    } catch {
      return;
    }
    const type = json?.type;
    if (type === 'ping') {
      send({type: 'pong'});
      return;
    }
    if (type === 'seat') {
      const interval = Number(json?.data?.keepIntervalSec);
      const seconds = Number.isFinite(interval) && interval > 0 ? Math.max(5, interval) : 30;
      if (keepSeatTimer) {
        clearInterval(keepSeatTimer);
      }
      send({type: 'keepSeat'});
      keepSeatTimer = setInterval(() => send({type: 'keepSeat'}), seconds * 1000);
      return;
    }
    if (type === 'messageServer') {
      const viewUri = json?.data?.viewUri;
      if (typeof viewUri === 'string' && viewUri) {
        pendingViewUri = viewUri;
      }
      return;
    }
    if (type === 'stream') {
      const uri = json?.data?.uri;
      if (typeof uri === 'string' && uri) {
        gotStream = true;
        cb.onStream({
          hlsUrl: uri,
          cookieHeader: buildCookieHeader(json?.data?.cookies),
          viewUri: pendingViewUri,
        });
      }
      return;
    }
    if (type === 'disconnect') {
      cb.onEnded?.();
      return;
    }
    if (type === 'error') {
      fail(`ニコ生エラー: ${json?.data?.code ?? 'unknown'}`);
    }
  };

  const connect = (data: WatchData) => {
    let url = data.wsUrl;
    if (data.frontendId && !/[?&]frontend_id=/.test(url)) {
      url += (url.includes('?') ? '&' : '?') + 'frontend_id=' + encodeURIComponent(data.frontendId);
    }
    try {
      socket = new WebSocket(url, undefined, {
        headers: {Origin: 'https://live.nicovideo.jp', 'User-Agent': mobileUserAgent},
      } as any);
    } catch (error) {
      fail(`ニコ生WebSocket失敗: ${error instanceof Error ? error.message : String(error)}`);
      return;
    }
    socket.onopen = () => {
      status('ニコ生接続済み');
      sendStartWatching();
    };
    socket.onmessage = event => handleText(String(event.data ?? ''));
    socket.onerror = () => status('ニコ生再接続待ち');
    socket.onclose = () => {
      if (!stopped && !gotStream) {
        fail('ニコ生WebSocketが再生前に切断されました');
      }
    };
  };

  (async () => {
    try {
      status('ニコ生視聴セッション取得中');
      const response = await fetch(watchURL, {
        headers: {
          'User-Agent': mobileUserAgent,
          Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6',
          // identity を明示しないと niconico が brotli を返し、Android(OkHttp)が
          // 復号できず "Network request failed" になる。
          'Accept-Encoding': 'identity',
        },
      });
      if (!response.ok) {
        fail(`ニコ生ページ取得失敗 HTTP ${response.status}`);
        return;
      }
      const html = await response.text();
      if (stopped) {
        return;
      }
      const data = parseNiconicoWatchData(html);
      if (!data) {
        fail('ニコ生WebSocket URLを解決できませんでした');
        return;
      }
      connect(data);
    } catch (error) {
      fail(`ニコ生視聴セッション失敗: ${error instanceof Error ? error.message : String(error)}`);
    }
  })();

  return {
    stop: () => {
      stopped = true;
      cleanup();
    },
  };
}

function buildCookieHeader(cookies: unknown): string | undefined {
  if (!Array.isArray(cookies)) {
    return undefined;
  }
  const parts = cookies
    .map(cookie => {
      const name = cookie?.name;
      const value = cookie?.value;
      return typeof name === 'string' && typeof value === 'string' ? `${name}=${value}` : null;
    })
    .filter((part): part is string => !!part);
  return parts.length ? parts.join('; ') : undefined;
}

function matchGroup(text: string, pattern: RegExp): string | null {
  const match = text.match(pattern);
  return match?.[1] ?? null;
}

function decodeHTMLEntities(value: string): string {
  return value
    .replace(/&quot;/g, '"')
    .replace(/&#34;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&#x2F;/gi, '/')
    .replace(/&#(\d+);/g, (_, code) => String.fromCharCode(Number(code)))
    .replace(/&amp;/g, '&');
}
