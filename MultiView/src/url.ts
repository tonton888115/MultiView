import { Settings, Stream } from './types';

// Builds the URL loaded into a stream cell's WebView.
// - niconico live can't be iframe-embedded, so we load its watch page directly.
// - everything else goes through the GitHub Pages player.html (embed + danmaku).
export function buildPlayerUrl(stream: Stream, settings: Settings): string | null {
  const channel = stream.channel.trim();

  if (stream.platform === 'niconico') {
    return `https://live.nicovideo.jp/watch/${encodeURIComponent(channel)}`;
  }

  const base = settings.baseUrl.trim().replace(/\/+$/, '');
  if (!base) {
    return null;
  }
  const parts = [
    `platform=${encodeURIComponent(stream.platform)}`,
    `channel=${encodeURIComponent(channel)}`,
    `chat=${settings.showChat ? '1' : '0'}`,
  ];
  if (settings.proxyUrl.trim()) {
    parts.push(`proxy=${encodeURIComponent(settings.proxyUrl.trim())}`);
  }
  return `${base}/player.html?${parts.join('&')}`;
}
