export type Platform = 'kick' | 'twitch' | 'youtube' | 'niconico' | 'twitcasting';

export interface Stream {
  id: string;
  platform: Platform;
  channel: string;
}

// Dr.Maggot-style danmaku filtering + appearance.
export interface DanmakuSettings {
  fontSize: number; // base px
  speed: number; // px per ms
  opacity: number; // 0..1
  maxLines: number; // 0 = auto (fit height)
  maxLength: number; // hide comments longer than this; 0 = no limit
  ngWords: string[]; // hide comments containing any of these
  ngUsers: string[]; // hide comments from these usernames (case-insensitive)
}

export interface Settings {
  // Whether to overlay NicoNico-style scrolling comments (danmaku)
  showChat: boolean;
  // Optional CORS proxy prefix for Kick/TwitCasting chat lookups (a Cloudflare Worker).
  // The target URL is appended url-encoded, e.g. "https://xxx.workers.dev/?url="
  proxyUrl: string;
  danmaku: DanmakuSettings;
}
