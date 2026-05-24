import { Platform, Settings } from './types';

export interface PlatformInfo {
  id: Platform;
  label: string;
  color: string;
  hint: string;
}

export const PLATFORMS: PlatformInfo[] = [
  { id: 'kick', label: 'Kick', color: '#53fc18', hint: 'チャンネル名 (例: xqc)' },
  { id: 'twitch', label: 'Twitch', color: '#9146ff', hint: 'チャンネル名 (例: shroud)' },
  { id: 'youtube', label: 'YouTube', color: '#ff0000', hint: '動画ID (例: jfKfPfyJRdk)' },
  { id: 'niconico', label: 'ニコ生', color: '#ff7e00', hint: '番組ID (例: lv123456789)' },
  { id: 'twitcasting', label: 'ツイキャス', color: '#00a0e9', hint: 'ユーザーID (例: twitcasting_jp)' },
];

export function platformInfo(id: Platform): PlatformInfo {
  return PLATFORMS.find(p => p.id === id) ?? PLATFORMS[0];
}

export const DEFAULT_SETTINGS: Settings = {
  showChat: true,
  proxyUrl: '',
  danmaku: {
    fontSize: 20,
    speed: 0.13,
    opacity: 0.9,
    maxLines: 0,
    maxLength: 0,
    ngWords: [],
    ngUsers: [],
  },
};

// Hosted player/chat pages (GitHub Pages of this repo). Hardcoded so the user
// never enters a URL. Loaded via {uri} so iframe video players actually play
// (loadHTMLString/baseUrl breaks iframe media on iOS WKWebView).
export const PAGES_BASE_URL = 'https://tonton888115.github.io/MultiView';

export const STORAGE_KEYS = {
  streams: 'mv.streams.v1',
  settings: 'mv.settings.v2',
};

// Beyond this, simultaneous playback gets heavy on iOS WebViews.
export const COMFORTABLE_STREAM_COUNT = 4;
