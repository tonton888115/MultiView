import {AppSettings, LayoutMode, PlatformId, StreamItem} from './types';

type CompactHandoffPayload = {
  v: number;
  s: Array<{p: PlatformId; c: string}>;
  layout?: LayoutMode;
};

const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';

function utf8ToBinary(value: string): string {
  return encodeURIComponent(value).replace(/%([0-9A-F]{2})/g, (_, hex: string) =>
    String.fromCharCode(parseInt(hex, 16)),
  );
}

function binaryToUtf8(value: string): string {
  const escaped = value
    .split('')
    .map(char => `%${char.charCodeAt(0).toString(16).padStart(2, '0')}`)
    .join('');
  return decodeURIComponent(escaped);
}

export function encodeBase64Utf8(value: string): string {
  let output = '';
  const input = utf8ToBinary(value);
  for (let i = 0; i < input.length; ) {
    const chr1 = input.charCodeAt(i++);
    const chr2 = input.charCodeAt(i++);
    const chr3 = input.charCodeAt(i++);
    const enc1 = chr1 >> 2;
    const enc2 = ((chr1 & 3) << 4) | (chr2 >> 4);
    const enc3 = Number.isNaN(chr2) ? 64 : ((chr2 & 15) << 2) | (chr3 >> 6);
    const enc4 = Number.isNaN(chr3) ? 64 : chr3 & 63;
    output += chars.charAt(enc1) + chars.charAt(enc2) + chars.charAt(enc3) + chars.charAt(enc4);
  }
  return output;
}

export function decodeBase64Utf8(value: string): string {
  const clean = value.replace(/[^A-Za-z0-9+/=]/g, '');
  let output = '';
  for (let i = 0; i < clean.length; ) {
    const enc1 = chars.indexOf(clean.charAt(i++));
    const enc2 = chars.indexOf(clean.charAt(i++));
    const enc3 = chars.indexOf(clean.charAt(i++));
    const enc4 = chars.indexOf(clean.charAt(i++));
    const chr1 = (enc1 << 2) | (enc2 >> 4);
    const chr2 = ((enc2 & 15) << 4) | (enc3 >> 2);
    const chr3 = ((enc3 & 3) << 6) | enc4;
    output += String.fromCharCode(chr1);
    if (enc3 !== 64) {
      output += String.fromCharCode(chr2);
    }
    if (enc4 !== 64) {
      output += String.fromCharCode(chr3);
    }
  }
  return binaryToUtf8(output);
}

export function compactHandoffCode(streams: StreamItem[], layout: LayoutMode): string {
  const payload: CompactHandoffPayload = {
    v: 1,
    s: streams.map(stream => ({p: stream.platform, c: stream.channel})),
    layout,
  };
  return encodeBase64Utf8(JSON.stringify(payload));
}

export function handoffURL(streams: StreamItem[], layout: LayoutMode): string {
  return `multiview://handoff?d=${encodeURIComponent(compactHandoffCode(streams, layout))}`;
}

export function decodeHandoff(raw: string): {streams: Array<Pick<StreamItem, 'platform' | 'channel'>>; settings: Partial<AppSettings>} {
  const value = raw.trim();
  if (!value) {
    throw new Error('empty');
  }
  let candidate = value;
  try {
    const url = new URL(value);
    const data = url.searchParams.get('d');
    if (data) {
      candidate = data;
    }
  } catch {
    // Raw JSON or raw base64 is also accepted.
  }

  let parsed: unknown;
  if (candidate.startsWith('{') || candidate.startsWith('[')) {
    parsed = JSON.parse(candidate);
  } else {
    parsed = JSON.parse(decodeBase64Utf8(candidate));
  }

  if (typeof parsed !== 'object' || parsed === null) {
    throw new Error('invalid');
  }
  const obj = parsed as {
    streams?: Array<Partial<StreamItem>>;
    settings?: Partial<AppSettings>;
    s?: Array<{p?: PlatformId; c?: string}>;
    layout?: LayoutMode;
  };
  if (Array.isArray(obj.s)) {
    return {
      streams: obj.s
        .filter(entry => entry.p && entry.c)
        .map(entry => ({platform: entry.p as PlatformId, channel: String(entry.c)})),
      settings: obj.layout ? {layoutMode: obj.layout} : {},
    };
  }
  if (Array.isArray(obj.streams)) {
    return {
      streams: obj.streams
        .filter(entry => entry.platform && entry.channel)
        .map(entry => ({platform: entry.platform as PlatformId, channel: String(entry.channel)})),
      settings: obj.settings ?? {},
    };
  }
  throw new Error('invalid');
}
