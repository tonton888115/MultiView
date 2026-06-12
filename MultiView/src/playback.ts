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
    return {
      kind: 'error',
      label: '取得失敗',
      status: 'フォールバック待機',
      reason: error instanceof Error ? error.message : String(error),
      fallbackUrl: webStreamURL(stream),
    };
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
      kind: 'web',
      url: webStreamURL(stream),
      label: 'YouTube Web',
      status: '動画ID未解決',
      reason: '@handle/live から現在のライブ動画IDを解決できませんでした。',
    };
  }
  if (settings.youtubePreferIframe) {
    return {
      kind: 'youtube-iframe',
      videoId,
      label: 'YouTube iframe',
      status: '公式エンジン/安定モード',
    };
  }
  const direct = await requestYouTubeDirect(videoId);
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
    kind: 'web',
    url: `https://m.youtube.com/watch?v=${encodeURIComponent(videoId)}`,
    label: 'YouTube Web',
    status: 'HLSなし/Webフォールバック',
    reason: 'YouTubeが直接HLSを返さないためWeb再生に切り替えました。',
  };
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

async function requestYouTubeDirect(videoId: string): Promise<{url: string; userAgent: string} | null> {
  const clients = youtubeClients();
  let fallback: {url: string; userAgent: string} | null = null;
  for (const client of clients) {
    try {
      const cpn = makeYouTubeCPN();
      const response = await fetchWithTimeout('https://youtubei.googleapis.com/youtubei/v1/player', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': client.userAgent,
          'X-YouTube-Client-Name': client.headerClientName,
          'X-YouTube-Client-Version': client.version,
          'Accept-Language': 'ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6',
        },
        body: JSON.stringify({
          context: client.context,
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
        }),
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
        fallback = fallback ?? {url: stream.url, userAgent: client.userAgent};
      }
    } catch {
      // Try the next InnerTube client.
    }
  }
  return fallback;
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

export function youtubeIframeHTML(videoId: string): string {
  const escaped = escapeHTML(videoId);
  return `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<style>
html,body,#player{margin:0;width:100%;height:100%;background:#000;overflow:hidden}
iframe{position:absolute;inset:0;width:100%;height:100%;border:0;background:#000}
#err{position:absolute;inset:0;display:none;align-items:center;justify-content:center;color:#fff;font-family:sans-serif;text-align:center;padding:18px;font-size:13px;line-height:1.5}
</style>
</head>
<body>
<div id="player"></div>
<div id="err"></div>
<script src="https://www.youtube.com/iframe_api"></script>
<script>
var player=null,READY=false,AUDIO=false,VOL=0,WANT_PLAY=true,lastPlayingAt=0,sb=[];
function apply(){
  if(!player||!READY)return;
  try{
    if(WANT_PLAY){player.playVideo();}
    if(AUDIO){player.unMute();player.setVolume(VOL);}else{player.mute();}
  }catch(e){}
}
function loadSB(){
  try{
    var cats='%5B%22sponsor%22%2C%22selfpromo%22%2C%22interaction%22%2C%22intro%22%2C%22outro%22%2C%22preview%22%2C%22music_offtopic%22%5D';
    fetch('https://sponsor.ajay.app/api/skipSegments?videoID=${escaped}&categories='+cats+'&actionTypes=%5B%22skip%22%5D')
      .then(function(r){return r.ok?r.json():[];})
      .then(function(list){sb=(list||[]).filter(function(s){return s.actionType==='skip'&&s.segment;}).map(function(s){return {s:s.segment[0],e:s.segment[1]};});})
      .catch(function(){});
  }catch(e){}
}
function sbTick(){
  if(!player||!READY||!sb.length)return;
  try{
    var t=player.getCurrentTime();
    for(var i=0;i<sb.length;i++){
      if(t>=sb[i].s&&t<sb[i].e-0.15){player.seekTo(sb[i].e+0.1,true);break;}
    }
  }catch(e){}
}
function showError(code){
  var el=document.getElementById('err');
  el.textContent='YouTube iframe error: '+code;
  el.style.display='flex';
}
window.onYouTubeIframeAPIReady=function(){
  player=new YT.Player('player',{
    width:'100%',height:'100%',videoId:'${escaped}',
    host:'https://www.youtube.com',
    playerVars:{autoplay:1,mute:1,playsinline:1,controls:0,rel:0,fs:0,iv_load_policy:3,modestbranding:1,origin:'https://tonton888115.github.io'},
    events:{
      onReady:function(){READY=true;apply();loadSB();},
      onStateChange:function(e){
        if(e.data===YT.PlayerState.PLAYING){lastPlayingAt=Date.now();return;}
        if(WANT_PLAY&&(e.data===YT.PlayerState.UNSTARTED||e.data===YT.PlayerState.CUED||e.data===YT.PlayerState.PAUSED||e.data===YT.PlayerState.BUFFERING)){
          setTimeout(function(){try{e.target.playVideo();}catch(x){}},250);
        }
      },
      onError:function(e){showError(e.data);}
    }
  });
};
window.mvPlay=function(){WANT_PLAY=true;apply();};
window.mvPause=function(){WANT_PLAY=false;try{player&&player.pauseVideo();}catch(e){}};
window.mvSetVolume=function(v){var n=Math.max(0,Math.min(1,+v||0));VOL=Math.round(n*100);AUDIO=VOL>0;apply();};
setInterval(sbTick,400);
setInterval(function(){
  if(!player||!READY||!WANT_PLAY)return;
  try{
    var state=player.getPlayerState();
    if(state!==YT.PlayerState.PLAYING&&Date.now()-lastPlayingAt>2500){player.playVideo();}
  }catch(e){}
},1200);
</script>
</body>
</html>`;
}

function escapeHTML(value: string): string {
  return value.replace(/[&<>"']/g, char => {
    switch (char) {
      case '&':
        return '&amp;';
      case '<':
        return '&lt;';
      case '>':
        return '&gt;';
      case '"':
        return '&quot;';
      default:
        return '&#39;';
    }
  });
}
