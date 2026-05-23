export type Platform = 'kick' | 'twitch' | 'niconico' | 'twitcasting';

export interface Stream {
  id: string;
  platform: Platform;
  channel: string;
}

export interface Settings {
  // GitHub Pages base URL that hosts player.html, e.g. https://user.github.io/MultiView
  baseUrl: string;
  // Whether to overlay NicoNico-style scrolling comments (danmaku)
  showChat: boolean;
  // Optional CORS proxy prefix for Kick/TwitCasting chat lookups (a Cloudflare Worker).
  // The target URL is appended url-encoded, e.g. "https://xxx.workers.dev/?url="
  proxyUrl: string;
}
