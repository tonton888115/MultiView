import { WEBVIEW_BASE_URL } from './config';
import {
  buildPlayerHtml,
  buildTwitchChatHtml,
  buildYouTubeChatHtml,
  playerConfigFor,
} from './playerHtml';
import { Settings, Stream } from './types';

export type CellSource = { uri: string } | { html: string; baseUrl: string };

const parentHost = WEBVIEW_BASE_URL.replace(/^https?:\/\//, '');

// WebView source for a stream's video cell.
// - niconico: load the watch page directly (no iframe embed exists for live)
// - others: bundled player HTML (embed + danmaku), no external hosting needed
export function streamSource(stream: Stream, settings: Settings): CellSource {
  const channel = stream.channel.trim();
  if (stream.platform === 'niconico') {
    return { uri: `https://live.nicovideo.jp/watch/${encodeURIComponent(channel)}` };
  }
  return {
    html: buildPlayerHtml(playerConfigFor(stream, settings)),
    baseUrl: WEBVIEW_BASE_URL,
  };
}

// WebView source for the inline chat (with input). Returns null when the platform
// has no separate chat surface (niconico's cell is already the full watch page).
export function chatSource(stream: Stream): CellSource | null {
  const channel = stream.channel.trim();
  switch (stream.platform) {
    case 'twitch':
      return { html: buildTwitchChatHtml(channel, parentHost), baseUrl: WEBVIEW_BASE_URL };
    case 'youtube':
      return { html: buildYouTubeChatHtml(channel, parentHost), baseUrl: WEBVIEW_BASE_URL };
    case 'kick':
      return { uri: `https://kick.com/${encodeURIComponent(channel)}` };
    case 'twitcasting':
      return { uri: `https://twitcasting.tv/${encodeURIComponent(channel)}` };
    default:
      return null;
  }
}
