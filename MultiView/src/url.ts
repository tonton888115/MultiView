import { PAGES_BASE_URL } from './config';
import { Settings, Stream } from './types';

export type CellSource = { uri: string };

function danmakuParams(settings: Settings): string {
  const d = settings.danmaku;
  const parts = [
    `chat=${settings.showChat ? '1' : '0'}`,
    `fs=${d.fontSize}`,
    `sp=${d.speed}`,
    `op=${d.opacity}`,
    `ml=${d.maxLines}`,
    `mlen=${d.maxLength}`,
    `audio=${settings.playAudio ? '1' : '0'}`,
  ];
  if (d.ngWords.length) {
    parts.push(`ng=${encodeURIComponent(d.ngWords.join(','))}`);
  }
  if (d.ngUsers.length) {
    parts.push(`ngu=${encodeURIComponent(d.ngUsers.join(','))}`);
  }
  if (settings.proxyUrl.trim()) {
    parts.push(`proxy=${encodeURIComponent(settings.proxyUrl.trim())}`);
  }
  return parts.join('&');
}

// Video cell source. Loaded via {uri} from the hosted page so iframe players
// actually play on iOS (loadHTMLString breaks iframe media).
export function streamSource(stream: Stream, settings: Settings): CellSource {
  const channel = encodeURIComponent(stream.channel.trim());
  if (stream.platform === 'niconico') {
    return { uri: `https://live.nicovideo.jp/watch/${channel}` };
  }
  const q = `platform=${stream.platform}&channel=${channel}&${danmakuParams(
    settings,
  )}`;
  return { uri: `${PAGES_BASE_URL}/player.html?${q}` };
}

// Inline chat (with input). null when the platform has no separate chat surface.
export function chatSource(stream: Stream): CellSource | null {
  const channel = encodeURIComponent(stream.channel.trim());
  switch (stream.platform) {
    case 'twitch':
      return {
        uri: `${PAGES_BASE_URL}/chat.html?platform=twitch&channel=${channel}`,
      };
    case 'youtube':
      return {
        uri: `${PAGES_BASE_URL}/chat.html?platform=youtube&channel=${channel}`,
      };
    case 'kick':
      return { uri: `https://kick.com/${channel}` };
    case 'twitcasting':
      return { uri: `https://twitcasting.tv/${channel}` };
    default:
      return null;
  }
}
