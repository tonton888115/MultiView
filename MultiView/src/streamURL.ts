import type {PlatformId} from './types';

const kickNonStreamPaths = new Set([
  'browse',
  'categories',
  'category',
  'following',
  'search',
  'clips',
  'about',
  'help',
  'dashboard',
  'messages',
  'settings',
  'subscriptions',
  'login',
  'signup',
  'auth',
  'oauth',
]);

const twitchNonStreamPaths = new Set([
  'directory',
  'videos',
  'login',
  'signup',
  'p',
  'settings',
  'subscriptions',
  'wallet',
  'drops',
  'u',
  'downloads',
  'jobs',
  'privacy',
  'terms',
  'turbo',
  'store',
]);

function stripWww(host: string): string {
  return host.replace(/^www\./, '').toLowerCase();
}

export function parseStreamURL(raw: string): {platform: PlatformId; channel: string} | null {
  try {
    const url = new URL(raw);
    const host = stripWww(url.hostname);
    const parts = url.pathname.split('/').filter(Boolean).map(decodeURIComponent);

    if (host === 'live-info.soraweb.net') {
      const linked = url.searchParams.get('link');
      if (linked) {
        const parsed = parseStreamURL(linked);
        if (parsed) {
          return parsed;
        }
      }
      const site = url.searchParams.get('site');
      const liveNo = url.searchParams.get('liveNo');
      if (site === 'nico' && liveNo) {
        return {platform: 'niconico', channel: liveNo.startsWith('lv') ? liveNo : `lv${liveNo}`};
      }
    }

    if (host === 'kick.com' && parts[0] && !kickNonStreamPaths.has(parts[0])) {
      return {platform: 'kick', channel: parts[0]};
    }
    if ((host === 'twitch.tv' || host === 'm.twitch.tv') && parts[0] && !twitchNonStreamPaths.has(parts[0])) {
      return {platform: 'twitch', channel: parts[0]};
    }
    if (host.includes('youtube.com')) {
      const videoId = url.searchParams.get('v');
      if (videoId) {
        return {platform: 'youtube', channel: videoId};
      }
      if (['live', 'embed', 'shorts'].includes(parts[0]) && parts[1]) {
        return {platform: 'youtube', channel: parts[1]};
      }
      if (parts[0]?.startsWith('@') || ['channel', 'c', 'user'].includes(parts[0])) {
        return {platform: 'youtube', channel: parts.join('/')};
      }
    }
    if (host === 'youtu.be' && parts[0]) {
      return {platform: 'youtube', channel: parts[0]};
    }
    if (host.includes('live.nicovideo.jp') && parts[0] === 'watch' && parts[1]) {
      return {platform: 'niconico', channel: parts.slice(1).join('/')};
    }
    if (host === 'twitcasting.tv' && parts[0] && parts[0] !== 'search') {
      return {platform: 'twitcasting', channel: parts[0]};
    }
  } catch {
    return null;
  }
  return null;
}
