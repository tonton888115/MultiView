import { Platform } from './types';

export interface ParsedStream {
  platform: Platform;
  channel: string;
}

// Parse an external stream URL (e.g. tapped on a ranking site) into platform + channel.
// Returns null for non-stream URLs (so the WebView can navigate normally).
export function parseStreamUrl(raw: string): ParsedStream | null {
  const m = /^https?:\/\/([^/?#]+)([^?#]*)(\?[^#]*)?/i.exec(raw);
  if (!m) {
    return null;
  }
  const host = m[1].replace(/^www\./, '').toLowerCase();
  const parts = (m[2] || '').split('/').filter(Boolean);
  const query = m[3] || '';
  const qparam = (k: string): string | null => {
    const mm = new RegExp('[?&]' + k + '=([^&]+)').exec(query);
    return mm ? decodeURIComponent(mm[1]) : null;
  };

  if (host === 'youtube.com' || host === 'm.youtube.com' || host === 'youtube-nocookie.com') {
    const v = qparam('v');
    if (v) {
      return { platform: 'youtube', channel: v };
    }
    if ((parts[0] === 'live' || parts[0] === 'embed' || parts[0] === 'shorts') && parts[1]) {
      return { platform: 'youtube', channel: parts[1] };
    }
    return null;
  }
  if (host === 'youtu.be' && parts[0]) {
    return { platform: 'youtube', channel: parts[0] };
  }

  if (host === 'twitch.tv' || host === 'm.twitch.tv') {
    const skip = ['videos', 'directory', 'p', 'settings', 'subscriptions', 'wallet', 'drops', 'u'];
    if (parts[0] && !skip.includes(parts[0])) {
      return { platform: 'twitch', channel: parts[0] };
    }
    return null;
  }

  if (host === 'kick.com' && parts[0]) {
    return { platform: 'kick', channel: parts[0] };
  }

  if (host === 'live.nicovideo.jp' || host === 'live2.nicovideo.jp') {
    if (parts[0] === 'watch' && parts[1]) {
      return { platform: 'niconico', channel: parts[1] };
    }
    return null;
  }
  if (host === 'nico.ms' && parts[0] && /^lv\d+/.test(parts[0])) {
    return { platform: 'niconico', channel: parts[0] };
  }

  if (host === 'twitcasting.tv' && parts[0] && parts[0] !== 'search') {
    return { platform: 'twitcasting', channel: parts[0] };
  }

  return null;
}
