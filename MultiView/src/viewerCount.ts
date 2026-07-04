import type {StreamItem} from './types';
import {fetchWithTimeout} from './network';
import {
  desktopUserAgent,
  mobileUserAgent,
  resolveLiveYouTubeVideoID,
  webStreamURL,
  youtubeClients,
  youtubeVideoId,
} from './playback';

const youtubeViewerKeys = ['concurrentViewers', 'concurrent_viewers'];
const niconicoCurrentViewerKeys = ['currentViewers', 'currentViewerCount', 'current_viewers', 'current_viewer_count', 'viewerCount', 'viewersCount'];
const youtubeViewerFetchTimeoutMs = 30000;
const youtubePlayerViewerFetchTimeoutMs = 8000;

export async function fetchViewerCount(stream: StreamItem): Promise<number | null> {
  switch (stream.platform) {
    case 'kick':
      return fetchKickViewerCount(stream.channel);
    case 'twitch':
      return fetchTwitchViewerCount(stream.channel);
    case 'youtube':
      return fetchYouTubeViewerCount(stream.channel);
    case 'niconico':
      return fetchHTMLViewerCount(webStreamURL(stream), niconicoCurrentViewerKeys);
    case 'twitcasting':
      return fetchHTMLViewerCount(webStreamURL(stream), ['current_view_count', 'currentViewerCount', 'current_viewer_count', 'viewer_count', 'viewerCount', 'viewers']);
  }
}

async function fetchKickViewerCount(rawChannel: string): Promise<number | null> {
  const channel = rawChannel.trim().replace(/^@+/, '').split(/[/?#\s]/)[0];
  const response = await fetch(`https://kick.com/api/v2/channels/${encodeURIComponent(channel)}`, {
    headers: {'User-Agent': desktopUserAgent, Accept: 'application/json'},
  });
  const json = await response.json();
  return json?.livestream
    ? numberFromKeys(json.livestream, ['viewer_count', 'viewerCount', 'viewers', 'viewersCount', 'currentViewers'])
    : null;
}

async function fetchTwitchViewerCount(rawChannel: string): Promise<number | null> {
  const channel = rawChannel.trim().replace(/^[@#]+/, '').split(/[/?#\s]/)[0].toLowerCase();
  const response = await fetch('https://gql.twitch.tv/gql', {
    method: 'POST',
    headers: {
      'Client-ID': 'kimne78kx3ncx6brgo4mv6wki5h1ko',
      'Content-Type': 'application/json',
      'User-Agent': desktopUserAgent,
    },
    body: JSON.stringify({
      operationName: 'ViewerCount',
      variables: {login: channel},
      query: 'query ViewerCount($login: String!) { user(login: $login) { stream { viewersCount } } }',
    }),
  });
  const json = await response.json();
  return toNumber(json?.data?.user?.stream?.viewersCount);
}

async function fetchYouTubeViewerCount(rawChannel: string): Promise<number | null> {
  let videoId = youtubeVideoId(rawChannel);
  try {
    videoId = videoId ?? await resolveLiveYouTubeVideoID(rawChannel);
  } catch {
    videoId = videoId ?? null;
  }
  if (videoId) {
    const firstCount = await firstViewerCount([
      fetchYouTubePlayerViewerCount(videoId),
      fetchYouTubeWatchViewerCount(videoId),
    ]);
    if (firstCount != null) {
      return firstCount;
    }
  }
  const url = youtubeViewerURL(rawChannel);
  if (!url) {
    return null;
  }
  const response = await fetchWithTimeout(url, {headers: {'User-Agent': desktopUserAgent}}, youtubeViewerFetchTimeoutMs);
  return youtubeViewerCountFromText(await response.text());
}

async function firstViewerCount(promises: Array<Promise<number | null>>): Promise<number | null> {
  return new Promise(resolve => {
    let pending = promises.length;
    let resolved = false;
    const settle = (value: number | null) => {
      if (!resolved && value != null) {
        resolved = true;
        resolve(value);
        return;
      }
      pending -= 1;
      if (!resolved && pending <= 0) {
        resolved = true;
        resolve(null);
      }
    };
    for (const promise of promises) {
      promise.then(settle).catch(() => settle(null));
    }
  });
}

async function fetchYouTubeWatchViewerCount(videoId: string): Promise<number | null> {
  try {
    const mobileResponse = await fetchWithTimeout(
      `https://m.youtube.com/watch?v=${encodeURIComponent(videoId)}`,
      {headers: {'User-Agent': mobileUserAgent, 'Accept-Language': 'ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6'}},
      youtubeViewerFetchTimeoutMs,
    );
    const mobileCount = youtubeViewerCountFromText(await mobileResponse.text());
    if (mobileCount != null) {
      return mobileCount;
    }
  } catch {
    // Try the desktop watch page below.
  }
  try {
    const response = await fetchWithTimeout(
      `https://www.youtube.com/watch?v=${encodeURIComponent(videoId)}`,
      {headers: {'User-Agent': desktopUserAgent}},
      youtubeViewerFetchTimeoutMs,
    );
    return youtubeViewerCountFromText(await response.text());
  } catch {
    return null;
  }
}

async function fetchYouTubePlayerViewerCount(videoId: string): Promise<number | null> {
  for (const client of youtubeClients()) {
    try {
      const response = await fetchWithTimeout(
        'https://youtubei.googleapis.com/youtubei/v1/player',
        {
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
          }),
        },
        youtubePlayerViewerFetchTimeoutMs,
      );
      if (!response.ok) {
        continue;
      }
      const count = youtubePlayerViewerCountFromJSON(await response.json());
      if (count != null) {
        return count;
      }
    } catch {
      // Try the next client/fallback path.
    }
  }
  return null;
}

async function fetchHTMLViewerCount(url: string, keys: string[]): Promise<number | null> {
  const response = await fetchWithTimeout(url, {headers: {'User-Agent': desktopUserAgent}}, youtubeViewerFetchTimeoutMs);
  const html = await response.text();
  return numberFromText(decodeHTMLEntities(html), keys);
}

function youtubeViewerURL(raw: string): string | null {
  const value = raw.trim();
  const id = value.match(/^[A-Za-z0-9_-]{11}$/)?.[0]
    ?? value.match(/[?&]v=([A-Za-z0-9_-]{11})/)?.[1]
    ?? value.match(/youtu\.be\/([A-Za-z0-9_-]{11})/)?.[1]
    ?? value.match(/\/(?:live|embed|shorts)\/([A-Za-z0-9_-]{11})/)?.[1];
  if (id) {
    return `https://www.youtube.com/watch?v=${encodeURIComponent(id)}`;
  }
  if (value.startsWith('@')) {
    return `https://www.youtube.com/${encodeURIComponent(value)}/live`;
  }
  return `https://www.youtube.com/@${encodeURIComponent(value.replace(/^@+/, ''))}/live`;
}

function numberFromKeys(value: unknown, keys: string[]): number | null {
  if (!value) {
    return null;
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      const count = numberFromKeys(item, keys);
      if (count != null) {
        return count;
      }
    }
    return null;
  }
  if (typeof value === 'object') {
    const object = value as Record<string, unknown>;
    for (const key of keys) {
      const count = toNumber(object[key]);
      if (count != null) {
        return count;
      }
    }
    for (const item of Object.values(object)) {
      const count = numberFromKeys(item, keys);
      if (count != null) {
        return count;
      }
    }
  }
  return null;
}

function numberFromText(text: string, keys: string[]): number | null {
  for (const key of keys) {
    const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const match = text.match(new RegExp(`"${escaped}"\\s*:?\\s*"?([0-9,]+)"?`, 'i'));
    const count = toNumber(match?.[1]);
    if (count != null) {
      return count;
    }
  }
  return null;
}

function youtubeViewerCountFromJSON(value: unknown): number | null {
  return youtubePlayerViewerCountFromJSON(value)
    ?? youtubePrimaryViewerCountFromJSON(value)
    ?? youtubeMobileViewerCountFromJSON(value)
    ?? numberFromKeys(value, youtubeViewerKeys);
}

function youtubePlayerViewerCountFromJSON(value: unknown): number | null {
  const object = value as any;
  return toNumber(object?.videoDetails?.concurrentViewers)
    ?? toNumber(object?.microformat?.playerMicroformatRenderer?.liveBroadcastDetails?.concurrentViewers);
}

function youtubeViewerCountFromText(text: string): number | null {
  const decoded = decodeHTMLEntities(text);
  const direct = numberFromText(decoded, youtubeViewerKeys);
  if (direct != null) {
    return direct;
  }
  for (const token of ['ytInitialPlayerResponse', 'ytInitialData']) {
    const assigned = jsonAssignedValueAfterToken(token, decoded);
    if (assigned) {
      try {
        const count = youtubeViewerCountFromJSON(JSON.parse(assigned));
        if (count != null) {
          return count;
        }
      } catch {
        const count = youtubeMobileViewerCountFromTextBlob(assigned);
        if (count != null) {
          return count;
        }
      }
    }
    const json = jsonObjectStringAfterToken(token, decoded);
    if (!json) {
      continue;
    }
    try {
      const count = youtubeViewerCountFromJSON(JSON.parse(json));
      if (count != null) {
        return count;
      }
    } catch {
      // Try the next embedded object.
    }
  }
  return null;
}

function youtubeMobileViewerCountFromTextBlob(text: string): number | null {
  if (!text.includes('"liveIndicatorText"')) {
    return null;
  }
  const match = text.match(
    /"slimVideoInformationRenderer"\s*:\s*\{[\s\S]{0,6000}?"collapsedSubtitle"\s*:\s*\{\s*"runs"\s*:\s*\[\s*\{\s*"text"\s*:\s*"([0-9][0-9,\s\u00a0]*)"\s*\}\s*,/,
  ) ?? text.match(
    /"slimVideoInformationRenderer"\s*:\s*\{[\s\S]{0,6000}?"expandedSubtitle"\s*:\s*\{\s*"runs"\s*:\s*\[\s*\{\s*"text"\s*:\s*"([0-9][0-9,\s\u00a0]*)"\s*\}\s*,/,
  );
  return toPlainNumber(match?.[1]);
}

function youtubeMobileViewerCountFromJSON(value: unknown): number | null {
  const object = value as any;
  const liveIndicator = object?.playerOverlays?.playerOverlayRenderer?.liveIndicatorText;
  const contents = object?.contents?.singleColumnWatchNextResults?.results?.results?.contents;
  if (!liveIndicator || !Array.isArray(contents)) {
    return null;
  }
  for (const item of contents) {
    const sectionContents = item?.slimVideoMetadataSectionRenderer?.contents;
    if (!Array.isArray(sectionContents)) {
      continue;
    }
    for (const sectionItem of sectionContents) {
      const info = sectionItem?.slimVideoInformationRenderer;
      const subtitles = [info?.collapsedSubtitle, info?.expandedSubtitle];
      for (const subtitle of subtitles) {
        const runs = subtitle?.runs;
        if (Array.isArray(runs) && runs.length > 1) {
          const count = toPlainNumber(runs[0]?.text);
          if (count != null) {
            return count;
          }
        }
      }
    }
  }
  return null;
}

function youtubePrimaryViewerCountFromJSON(value: unknown): number | null {
  const object = value as any;
  const contents = object?.contents?.twoColumnWatchNextResults?.results?.results?.contents;
  if (!Array.isArray(contents)) {
    return null;
  }
  for (const item of contents) {
    const renderer = item?.videoPrimaryInfoRenderer?.viewCount?.videoViewCountRenderer;
    const count = youtubeVideoViewCountRendererCount(renderer);
    if (count != null) {
      return count;
    }
  }
  return null;
}

function youtubeVideoViewCountRendererCount(renderer: any): number | null {
  if (!renderer || renderer.isLive !== true) {
    return null;
  }
  return toNumber(renderer.originalViewCount);
}

function jsonAssignedValueAfterToken(token: string, text: string): string | null {
  const marker = `var ${token} =`;
  const markerIndex = text.indexOf(marker);
  if (markerIndex < 0) {
    return null;
  }
  let index = markerIndex + marker.length;
  while (/\s/.test(text[index] ?? '')) {
    index += 1;
  }
  const quote = text[index];
  if (quote === '"' || quote === "'") {
    let escaping = false;
    let raw = '';
    for (index += 1; index < text.length; index += 1) {
      const character = text[index];
      if (escaping) {
        raw += `\\${character}`;
        escaping = false;
      } else if (character === '\\') {
        escaping = true;
      } else if (character === quote) {
        return decodeJavaScriptStringLiteral(raw);
      } else {
        raw += character;
      }
    }
    return null;
  }
  if (text[index] === '{') {
    return jsonObjectStringAt(index, text);
  }
  return null;
}

function jsonObjectStringAfterToken(token: string, text: string): string | null {
  let position = 0;
  while (position < text.length) {
    const tokenIndex = text.indexOf(token, position);
    if (tokenIndex < 0) {
      return null;
    }
    const start = text.indexOf('{', tokenIndex + token.length);
    if (start < 0) {
      return null;
    }
    const json = jsonObjectStringAt(start, text);
    if (json) {
      return json;
    }
    position = tokenIndex + token.length;
  }
  return null;
}

function jsonObjectStringAt(start: number, text: string): string | null {
  let depth = 0;
  let inString = false;
  let escaping = false;
  for (let index = start; index < text.length; index += 1) {
    const character = text[index];
    if (inString) {
      if (escaping) {
        escaping = false;
      } else if (character === '\\') {
        escaping = true;
      } else if (character === '"') {
        inString = false;
      }
    } else if (character === '"') {
      inString = true;
    } else if (character === '{') {
      depth += 1;
    } else if (character === '}') {
      depth -= 1;
      if (depth === 0) {
        return text.slice(start, index + 1);
      }
    }
  }
  return null;
}

function decodeJavaScriptStringLiteral(text: string): string {
  return text
    .replace(/\\x([0-9a-fA-F]{2})/g, (_, hex: string) => String.fromCharCode(parseInt(hex, 16)))
    .replace(/\\u([0-9a-fA-F]{4})/g, (_, hex: string) => String.fromCharCode(parseInt(hex, 16)))
    .replace(/\\n/g, '\\n')
    .replace(/\\r/g, '\\r')
    .replace(/\\t/g, '\\t')
    .replace(/\\([^"\\/bfnrtu])/g, '$1')
    .replace(/\\\//g, '/')
    .replace(/\\"/g, '"')
    .replace(/\\'/g, "'")
    .replace(/\\\\/g, '\\');
}

function decodeHTMLEntities(text: string): string {
  return text
    .replace(/&quot;/g, '"')
    .replace(/&#34;/g, '"')
    .replace(/&#x22;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#x27;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
}

function toNumber(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.max(0, Math.round(value));
  }
  if (typeof value === 'string') {
    const parsed = Number(value.replace(/[,人\s]/g, ''));
    return Number.isFinite(parsed) ? Math.max(0, Math.round(parsed)) : null;
  }
  return null;
}

function toPlainNumber(value: unknown): number | null {
  if (typeof value === 'number') {
    return toNumber(value);
  }
  if (typeof value !== 'string' || !/^\s*[0-9][0-9,\s\u00a0]*\s*$/.test(value)) {
    return null;
  }
  return toNumber(value);
}
