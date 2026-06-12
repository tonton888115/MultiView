import {AppSettings, PlaybackQuality, PlaybackSource, PlatformId, StreamItem} from './types';

export const mobileUserAgent =
  'Mozilla/5.0 (Linux; Android 15; Pixel 9 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36';

export const desktopUserAgent =
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';

const mobileSafariUserAgent =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1';

const youtubeIOSVersion = '21.17.3';
const youtubeIOSStableVersion = '21.13.6';
const youtubeAndroidVersion = '20.19.35';
const twitchClientID = 'kimne78kx3ncx6brgo4mv6wki5h1ko';
const twitchAccessTokenHash = '0828119ded1c13477966434e15800ff57ddacf13ba1911c129dc2200705b0712';

export function cleanChannel(raw: string): string {
  return raw.trim().replace(/^@+/, '@');
}

export function streamKey(platform: PlatformId, channel: string): string {
  return `${platform}:${cleanChannel(channel).toLowerCase()}`;
}

export function makeStream(platform: PlatformId, channel: string): StreamItem {
  const clean = cleanChannel(channel);
  return {
    id: streamKey(platform, clean),
    platform,
    channel: clean,
  };
}

export function effectiveQuality(settings: AppSettings, streamCount: number): PlaybackQuality {
  if (settings.autoEconomyOnManyStreams && streamCount >= 3) {
    return 'economy';
  }
  return settings.wifiQuality;
}

export function webStreamURL(stream: StreamItem): string {
  const channel = cleanChannel(stream.channel);
  switch (stream.platform) {
    case 'kick':
      return `https://kick.com/${encodeURIComponent(channel)}`;
    case 'twitch':
      return `https://m.twitch.tv/${encodeURIComponent(channel)}`;
    case 'youtube': {
      const id = youtubeVideoId(channel);
      if (id) {
        return `https://www.youtube.com/watch?v=${encodeURIComponent(id)}`;
      }
      const path = channel.startsWith('@') || channel.includes('/') ? channel : `@${channel}`;
      return `https://m.youtube.com/${path.replace(/^\/+/, '')}/live`;
    }
    case 'niconico':
      return `https://live.nicovideo.jp/watch/${encodeURIComponent(channel)}`;
    case 'twitcasting':
      return `https://twitcasting.tv/${encodeURIComponent(channel)}`;
  }
}

export function chatURL(stream: StreamItem): string | null {
  const channel = cleanChannel(stream.channel);
  switch (stream.platform) {
    case 'twitch':
      return `https://www.twitch.tv/popout/${encodeURIComponent(channel)}/chat?popout=`;
    case 'youtube': {
      const id = youtubeVideoId(channel);
      return id ? `https://www.youtube.com/live_chat?v=${encodeURIComponent(id)}&embed_domain=tonton888115.github.io` : null;
    }
    case 'kick':
      return `https://kick.com/${encodeURIComponent(channel)}/chatroom`;
    case 'niconico':
      return `https://live.nicovideo.jp/watch/${encodeURIComponent(channel)}`;
    case 'twitcasting':
      return `https://twitcasting.tv/${encodeURIComponent(channel)}`;
  }
}

export async function resolvePlaybackSource(
  stream: StreamItem,
  settings: AppSettings,
  streamCount: number,
): Promise<PlaybackSource> {
  try {
    switch (stream.platform) {
      case 'kick':
        return await resolveKick(stream);
      case 'twitch':
        return await resolveTwitch(stream);
      case 'youtube':
        return await resolveYouTube(stream, settings);
      case 'twitcasting':
        return await resolveTwitcasting(stream);
      case 'niconico':
        return niconicoWebFallback(stream, settings, streamCount);
    }
  } catch (error) {
    const source: PlaybackSource = {
      kind: 'error',
      label: '取得失敗',
      status: 'フォールバック待機',
      reason: error instanceof Error ? error.message : String(error),
    };
    if (stream.platform !== 'youtube') {
      source.fallbackUrl = webStreamURL(stream);
    }
    return source;
  }
}

async function resolveKick(stream: StreamItem): Promise<PlaybackSource> {
  const channel = cleanChannel(stream.channel);
  const url = `https://kick.com/api/v2/channels/${encodeURIComponent(channel)}`;
  const headers = kickHeaders(channel);
  const response = await fetch(url, {headers});
  if (!response.ok) {
    throw new Error(`Kick HTTP ${response.status}`);
  }
  const json = await response.json();
  const livestream = json?.livestream;
  const hls = livestream
    ? stringValue(livestream?.playback_url)
      ?? findHlsURL(livestream)
      ?? stringValue(json?.playback_url)
      ?? findHlsURL(json)
    : null;
  if (!hls) {
    return {
      kind: 'error',
      label: 'Kick',
      status: 'オフライン',
      reason: '現在ライブ配信ではありません。',
    };
  }
  const playbackHeaders = kickPlaybackHeaders(channel);
  return {
    kind: 'native',
    url: hls,
    headers: playbackHeaders,
    label: 'Kick HLS',
    status: '独自プレイヤー',
  };
}

function findHlsURL(value: unknown): string | null {
  if (!value) {
    return null;
  }
  if (typeof value === 'string') {
    return /\.m3u8(?:\?|$)/.test(value) ? value : null;
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findHlsURL(item);
      if (found) {
        return found;
      }
    }
    return null;
  }
  if (typeof value === 'object') {
    for (const item of Object.values(value)) {
      const found = findHlsURL(item);
      if (found) {
        return found;
      }
    }
  }
  return null;
}

async function resolveTwitch(stream: StreamItem): Promise<PlaybackSource> {
  const channel = normalizeTwitchChannel(stream.channel);
  if (!channel) {
    throw new Error('Twitchチャンネル名が不正です');
  }
  const body = {
    operationName: 'PlaybackAccessToken',
    extensions: {
      persistedQuery: {
        version: 1,
        sha256Hash: twitchAccessTokenHash,
      },
    },
    variables: {
      isLive: true,
      login: channel,
      isVod: false,
      vodID: '',
      playerType: 'embed',
    },
  };
  const response = await fetch('https://gql.twitch.tv/gql', {
    method: 'POST',
    headers: {
      'Client-ID': twitchClientID,
      'Content-Type': 'application/json',
      'User-Agent': mobileSafariUserAgent,
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    throw new Error(`Twitch GQL HTTP ${response.status}`);
  }
  const json = await response.json();
  const token = json?.data?.streamPlaybackAccessToken;
  const value = stringValue(token?.value);
  const signature = stringValue(token?.signature);
  if (!value || !signature) {
    return {
      kind: 'web',
      url: webStreamURL(stream),
      label: 'Twitch Web',
      status: '配信情報なし',
      reason: 'オフライン、限定配信、またはTwitch側の制限です。',
    };
  }
  const hls = buildTwitchUsherURL(channel, value, signature);
  return {
    kind: 'native',
    url: hls,
    headers: {
      'User-Agent': mobileSafariUserAgent,
      Referer: 'https://player.twitch.tv/',
      Origin: 'https://player.twitch.tv',
    },
    label: 'Twitch HLS',
    status: '独自プレイヤー',
  };
}

async function resolveYouTube(stream: StreamItem, settings: AppSettings): Promise<PlaybackSource> {
  const raw = cleanChannel(stream.channel);
  const videoId = youtubeVideoId(raw) ?? (await resolveLiveYouTubeVideoID(raw));
  if (!videoId) {
    return {
      kind: 'error',
      label: 'YouTube HLS',
      status: '動画ID未解決',
      reason: '@handle/live から現在のライブ動画IDを解決できませんでした。',
    };
  }
  const direct = await requestYouTubeDirect(videoId, settings);
  if (direct) {
    return {
      kind: 'native',
      url: direct.url,
      headers: {'User-Agent': direct.userAgent, Referer: 'https://www.youtube.com/'},
      liveTargetOffsetMs: settings.youtubeStableBuffer ? 12000 : 8000,
      label: 'YouTube HLS',
      status: '独自プレイヤー/直HLS',
    };
  }
  return {
    kind: 'error',
    label: 'YouTube HLS',
    status: 'HLS再取得待ち',
    reason: hasYouTubePlaybackAuth(settings)
      ? 'YouTubeが入力済みのHLS認証材料でも直接HLSを返していません。公式Web再生には切り替えず再取得します。'
      : 'YouTubeがbot確認でHLSを返していません。設定でYouTube HLS Cookie、PO Token、Visitor Dataを入力してください。公式Web再生には切り替えません。',
  };
}

function hasYouTubePlaybackAuth(settings: AppSettings): boolean {
  return Boolean(
    settings.youtubeCookie.trim()
    || settings.youtubePoToken.trim()
    || settings.youtubeVisitorData.trim()
  );
}

async function resolveTwitcasting(stream: StreamItem): Promise<PlaybackSource> {
  const channel = cleanChannel(stream.channel);
  const target = encodeURIComponent(channel);
  const url = `https://twitcasting.tv/streamserver.php?target=${target}&mode=client&player=pc_web`;
  const response = await fetch(url, {
    headers: {
      Accept: 'application/json, text/plain, */*',
      'Accept-Language': 'ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6',
      'User-Agent': mobileSafariUserAgent,
      Referer: `https://twitcasting.tv/${channel}`,
      Origin: 'https://twitcasting.tv',
      'X-Requested-With': 'XMLHttpRequest',
    },
  });
  if (!response.ok) {
    throw new Error(`ツイキャス HTTP ${response.status}`);
  }
  const json = await response.json();
  const liveValue = json?.movie?.live;
  const isLive = liveValue === true || liveValue === 1;
  const streams = json?.['tc-hls']?.streams ?? {};
  const hls = ['medium', 'high', 'low', 'base', 'mobilesource', 'main']
    .map(key => stringValue(streams[key]))
    .find(Boolean) ?? Object.values(streams).map(stringValue).find(Boolean);
  if (!hls) {
    return {
      kind: 'web',
      url: webStreamURL(stream),
      label: 'TwitCasting Web',
      status: isLive ? 'HLSなし' : 'オフライン',
      reason: isLive ? 'ツイキャスのHLS URLを取得できませんでした。' : '現在ライブ配信ではありません。',
    };
  }
  return {
    kind: 'native',
    url: hls,
    headers: {
      'User-Agent': mobileSafariUserAgent,
      Referer: `https://twitcasting.tv/${channel}`,
    },
    label: 'TwitCasting HLS',
    status: '独自プレイヤー',
  };
}

function niconicoWebFallback(stream: StreamItem, settings: AppSettings, streamCount: number): PlaybackSource {
  const quality = effectiveQuality(settings, streamCount);
  return {
    kind: 'web',
    url: webStreamURL(stream),
    label: `Niconico Web/${quality}`,
    status: 'Webフォールバック',
    reason: 'ニコ生のHLS取得はWebSocket視聴セッション移植が未完了です。',
  };
}

function kickHeaders(channel: string): Record<string, string> {
  return {
    Accept: 'application/json, text/plain, */*',
    'User-Agent': mobileSafariUserAgent,
    Referer: `https://kick.com/${channel}`,
    Origin: 'https://kick.com',
  };
}

function kickPlaybackHeaders(channel: string): Record<string, string> {
  return {
    'User-Agent': mobileSafariUserAgent,
    Referer: `https://kick.com/${channel}`,
    Origin: 'https://kick.com',
  };
}

function buildTwitchUsherURL(channel: string, token: string, signature: string): string {
  const params = new URLSearchParams({
    sig: signature,
    token,
    allow_source: 'true',
    allow_audio_only: 'true',
    player: 'twitchweb',
    p: String(Math.floor(Math.random() * 1_000_000)),
    type: 'any',
    fast_bread: 'true',
    playlist_include_framerate: 'true',
  });
  return `https://usher.ttvnw.net/api/channel/hls/${encodeURIComponent(channel)}.m3u8?${params.toString()}`;
}

function normalizeTwitchChannel(raw: string): string {
  let value = raw.trim().toLowerCase();
  const marker = 'twitch.tv/';
  const markerIndex = value.indexOf(marker);
  if (markerIndex >= 0) {
    value = value.slice(markerIndex + marker.length);
  }
  return value.split(/[/?#]/)[0].replace(/^@+/, '');
}

export function youtubeVideoId(raw: string): string | null {
  const trimmed = raw.trim();
  if (/^[A-Za-z0-9_-]{11}$/.test(trimmed)) {
    return trimmed;
  }
  const normalized = /^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : `https://youtube.com/${trimmed}`;
  try {
    const url = new URL(normalized);
    const host = url.hostname.replace(/^www\./, '').toLowerCase();
    const parts = url.pathname.split('/').filter(Boolean).map(decodeURIComponent);
    if (host === 'youtu.be' && /^[A-Za-z0-9_-]{11}$/.test(parts[0] ?? '')) {
      return parts[0];
    }
    const v = url.searchParams.get('v');
    if (host.includes('youtube.com') && v && /^[A-Za-z0-9_-]{11}$/.test(v)) {
      return v;
    }
    if (host.includes('youtube.com') && ['live', 'embed', 'shorts'].includes(parts[0]) && /^[A-Za-z0-9_-]{11}$/.test(parts[1] ?? '')) {
      return parts[1];
    }
  } catch {
    return null;
  }
  return null;
}

export async function resolveLiveYouTubeVideoID(raw: string): Promise<string | null> {
  const url = liveResolutionURL(raw);
  if (!url) {
    return null;
  }
  const response = await fetchWithTimeout(url, {
    headers: {
      'User-Agent': mobileSafariUserAgent,
      'Accept-Language': 'ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6',
    },
  }, 10000);
  if (!response.ok) {
    return null;
  }
  const finalId = youtubeVideoId(response.url);
  if (finalId) {
    return finalId;
  }
  const html = await response.text();
  return extractYouTubeVideoID(html);
}

function liveResolutionURL(raw: string): string | null {
  const trimmed = raw.trim();
  try {
    const url = new URL(trimmed);
    if (url.hostname.toLowerCase().includes('youtube.com')) {
      const parts = url.pathname.split('/').filter(Boolean);
      if (parts[0]?.startsWith('@')) {
        return `https://www.youtube.com/${parts[0]}/live`;
      }
      return trimmed;
    }
  } catch {
    // Plain handles are handled below.
  }
  const handle = trimmed.replace(/^@+/, '');
  return handle ? `https://www.youtube.com/@${encodeURIComponent(handle)}/live` : null;
}

function extractYouTubeVideoID(html: string): string | null {
  const patterns = [
    /"videoId"\s*:\s*"([A-Za-z0-9_-]{11})"/,
    /watch\?v=([A-Za-z0-9_-]{11})/,
    /\/embed\/([A-Za-z0-9_-]{11})/,
  ];
  for (const pattern of patterns) {
    const match = html.match(pattern);
    if (match?.[1]) {
      return match[1];
    }
  }
  return null;
}

type YouTubePlayableStream = {
  url: string;
  kind: 'hls' | 'progressive';
  isLive: boolean;
  hasSabr: boolean;
};

async function requestYouTubeDirect(videoId: string, settings: AppSettings): Promise<{url: string; userAgent: string} | null> {
  const clients = youtubeClients();
  for (const client of clients) {
    try {
      const cpn = makeYouTubeCPN();
      const auth = youtubePlaybackAuth(settings, 'https://www.youtube.com');
      const context = auth.visitorData ? withYouTubeVisitorData(client.context, auth.visitorData) : client.context;
      const body: Record<string, unknown> = {
        context,
        videoId,
        contentCheckOk: true,
        racyCheckOk: true,
        playbackContext: {
          contentPlaybackContext: {
            html5Preference: 'HTML5_PREF_WANTS',
            referer: `https://www.youtube.com/watch?v=${videoId}`,
            cpn,
          },
        },
      };
      if (auth.poToken) {
        body.serviceIntegrityDimensions = {poToken: auth.poToken};
      }
      const response = await fetchWithTimeout('https://youtubei.googleapis.com/youtubei/v1/player', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': client.userAgent,
          'X-YouTube-Client-Name': client.headerClientName,
          'X-YouTube-Client-Version': client.version,
          'Accept-Language': 'ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6',
          ...auth.headers,
        },
        body: JSON.stringify(body),
      }, 12000);
      if (!response.ok) {
        continue;
      }
      const json = await response.json();
      const stream = extractPlayableYouTubeStream(json);
      if (stream) {
        if (stream.kind === 'hls' || !stream.isLive) {
          return {url: stream.url, userAgent: client.userAgent};
        }
      }
    } catch {
      // Try the next InnerTube client.
    }
  }
  return null;
}

async function fetchWithTimeout(url: string, init: RequestInit, timeoutMs: number): Promise<Response> {
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

function youtubePlaybackAuth(settings: AppSettings, origin: string): {headers: Record<string, string>; poToken?: string; visitorData?: string} {
  const cookie = settings.youtubeCookie.trim();
  const poToken = settings.youtubePoToken.trim();
  const visitorData = settings.youtubeVisitorData.trim();
  const headers: Record<string, string> = {};
  if (cookie) {
    headers.Cookie = cookie;
    const sapisid = youtubeCookieValue(cookie, ['SAPISID', '__Secure-1PAPISID', '__Secure-3PAPISID']);
    if (sapisid) {
      const timestamp = Math.floor(Date.now() / 1000);
      headers.Authorization = `SAPISIDHASH ${timestamp}_${sha1Hex(`${timestamp} ${decodeURIComponentSafe(sapisid)} ${origin}`)}`;
      headers.Origin = origin;
      headers['X-Origin'] = origin;
    }
  }
  if (visitorData) {
    headers['X-Goog-Visitor-Id'] = visitorData;
  }
  return {
    headers,
    ...(poToken ? {poToken} : {}),
    ...(visitorData ? {visitorData} : {}),
  };
}

function withYouTubeVisitorData(context: Record<string, unknown>, visitorData: string): Record<string, unknown> {
  const client = typeof context.client === 'object' && context.client ? context.client as Record<string, unknown> : {};
  return {
    ...context,
    client: {
      ...client,
      visitorData,
    },
  };
}

function youtubeCookieValue(cookie: string, names: string[]): string | null {
  const values = cookie.split(';');
  for (const part of values) {
    const [rawName, ...rawValue] = part.trim().split('=');
    if (names.includes(rawName) && rawValue.length) {
      return rawValue.join('=');
    }
  }
  return null;
}

function decodeURIComponentSafe(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

/* eslint-disable no-bitwise */
function sha1Hex(input: string): string {
  const bytes = Array.from(unescape(encodeURIComponent(input)), char => char.charCodeAt(0));
  const bitLength = bytes.length * 8;
  bytes.push(0x80);
  while ((bytes.length % 64) !== 56) {
    bytes.push(0);
  }
  const high = Math.floor(bitLength / 0x100000000);
  const low = bitLength >>> 0;
  for (let i = 3; i >= 0; i -= 1) {
    bytes.push((high >>> (i * 8)) & 0xff);
  }
  for (let i = 3; i >= 0; i -= 1) {
    bytes.push((low >>> (i * 8)) & 0xff);
  }
  let h0 = 0x67452301;
  let h1 = 0xefcdab89;
  let h2 = 0x98badcfe;
  let h3 = 0x10325476;
  let h4 = 0xc3d2e1f0;
  for (let i = 0; i < bytes.length; i += 64) {
    const words = new Array<number>(80);
    for (let j = 0; j < 16; j += 1) {
      words[j] = (bytes[i + j * 4] << 24) | (bytes[i + j * 4 + 1] << 16) | (bytes[i + j * 4 + 2] << 8) | bytes[i + j * 4 + 3];
    }
    for (let j = 16; j < 80; j += 1) {
      const value = words[j - 3] ^ words[j - 8] ^ words[j - 14] ^ words[j - 16];
      words[j] = (value << 1) | (value >>> 31);
    }
    let a = h0;
    let b = h1;
    let c = h2;
    let d = h3;
    let e = h4;
    for (let j = 0; j < 80; j += 1) {
      let f: number;
      let k: number;
      if (j < 20) {
        f = (b & c) | (~b & d);
        k = 0x5a827999;
      } else if (j < 40) {
        f = b ^ c ^ d;
        k = 0x6ed9eba1;
      } else if (j < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8f1bbcdc;
      } else {
        f = b ^ c ^ d;
        k = 0xca62c1d6;
      }
      const temp = (((a << 5) | (a >>> 27)) + f + e + k + words[j]) | 0;
      e = d;
      d = c;
      c = (b << 30) | (b >>> 2);
      b = a;
      a = temp;
    }
    h0 = (h0 + a) | 0;
    h1 = (h1 + b) | 0;
    h2 = (h2 + c) | 0;
    h3 = (h3 + d) | 0;
    h4 = (h4 + e) | 0;
  }
  return [h0, h1, h2, h3, h4].map(word => (word >>> 0).toString(16).padStart(8, '0')).join('');
}
/* eslint-enable no-bitwise */

function youtubeClients() {
  const currentIosUA = youtubeIOSUserAgent(youtubeIOSVersion);
  const stableIosUA = youtubeIOSUserAgent(youtubeIOSStableVersion);
  const androidUA = `com.google.android.youtube/${youtubeAndroidVersion} (Linux; U; Android 15) gzip`;
  return [
    {
      headerClientName: '3',
      version: youtubeAndroidVersion,
      userAgent: androidUA,
      context: {
        client: withYouTubeClientDefaults({
          clientName: 'ANDROID',
          clientVersion: youtubeAndroidVersion,
          androidSdkVersion: 35,
          deviceMake: 'Google',
          deviceModel: 'Pixel 9 Pro',
          osName: 'Android',
          osVersion: '15',
          userAgent: androidUA,
        }),
      },
    },
    {
      headerClientName: '5',
      version: youtubeIOSStableVersion,
      userAgent: stableIosUA,
      context: {
        client: withYouTubeClientDefaults({
          clientName: 'IOS',
          clientVersion: youtubeIOSStableVersion,
          deviceMake: 'Apple',
          deviceModel: 'iPhone16,2',
          osName: 'iOS',
          osVersion: '17.5.1.21F90',
          userAgent: stableIosUA,
        }),
      },
    },
    {
      headerClientName: '5',
      version: youtubeIOSVersion,
      userAgent: currentIosUA,
      context: {
        client: withYouTubeClientDefaults({
          clientName: 'IOS',
          clientVersion: youtubeIOSVersion,
          deviceMake: 'Apple',
          deviceModel: 'iPhone16,2',
          osName: 'iOS',
          osVersion: '17.5.1.21F90',
          userAgent: currentIosUA,
        }),
      },
    },
  ];
}

function youtubeIOSUserAgent(version: string): string {
  return `com.google.ios.youtube/${version} (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X; ja_JP)`;
}

function withYouTubeClientDefaults<T extends Record<string, unknown>>(client: T): T & Record<string, unknown> {
  return {
    ...client,
    hl: 'ja',
    gl: 'JP',
    timeZone: 'Asia/Tokyo',
    utcOffsetMinutes: 540,
    screenDensityFloat: 3,
    screenWidthPoints: 393,
    screenHeightPoints: 852,
  };
}

function makeYouTubeCPN(): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  let out = '';
  for (let i = 0; i < 16; i += 1) {
    out += chars[Math.floor(Math.random() * chars.length)];
  }
  return out;
}

function extractPlayableYouTubeStream(json: any): YouTubePlayableStream | null {
  const streamingData = json?.streamingData;
  if (!streamingData) {
    return null;
  }
  const details = json?.videoDetails;
  const isLive = details?.isLive === true || details?.isLiveContent === true;
  const hasSabr = Boolean(stringValue(streamingData.serverAbrStreamingUrl));
  const hls = stringValue(streamingData.hlsManifestUrl);
  if (hls) {
    return {url: hls, kind: 'hls', isLive, hasSabr};
  }
  const formats = [...(streamingData.formats ?? []), ...(streamingData.adaptiveFormats ?? [])];
  const candidates = formats
    .map((format: any) => {
      const url = stringValue(format?.url);
      const mime = stringValue(format?.mimeType) ?? '';
      const hasAudio = !mime.includes('video/') || mime.includes('mp4a') || format?.hasAudio === true;
      if (!url || !hasAudio) {
        return null;
      }
      return {
        url,
        height: Number(format?.height ?? 0),
        bitrate: Number(format?.bitrate ?? 0),
      };
    })
    .filter(Boolean) as Array<{url: string; height: number; bitrate: number}>;
  candidates.sort((a, b) => b.height - a.height || b.bitrate - a.bitrate);
  const progressive = candidates[0]?.url;
  return progressive ? {url: progressive, kind: 'progressive', isLive, hasSabr} : null;
}

function stringValue(value: unknown): string | null {
  if (typeof value === 'string' && value.trim()) {
    return value;
  }
  if (typeof value === 'number') {
    return String(value);
  }
  return null;
}
