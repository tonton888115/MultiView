import {extractPlayableYouTubeURL} from '../playback';

declare const __dirname: string;

const fs = require('fs') as {readFileSync(filePath: string, encoding: 'utf8'): string};
const path = require('path') as {join(...parts: string[]): string; resolve(...parts: string[]): string};

const projectRoot = path.resolve(__dirname, '..', '..');

function readProjectFile(relativePath: string): string {
  return fs.readFileSync(path.join(projectRoot, relativePath), 'utf8');
}

describe('YouTube playback regression harness', () => {
  const runtimeFiles = [
    'App.tsx',
    'src/playback.ts',
    'src/types.ts',
    'ios/MultiView/BrowserUserAgent.swift',
    'ios/MultiView/YouTubePlayer.swift',
    'src/YouTubeOfficialChatBridge.tsx',
    'android/app/src/main/java/com/multiview/NativeHlsPlayerView.kt',
  ];

  it('does not reintroduce rejected YouTube HLS routes', () => {
    const combined = runtimeFiles.map(readProjectFile).join('\n');

    [
      /multiview\.rinngo0626\.workers\.dev/,
      /extractionWorkerURL/,
      /workers\.dev/,
      /youtubeCookie|youtubePoToken|youtubeVisitorData/,
      /HLS Cookie|PO Token|bot確認でHLS/,
      /youtubeIOSStableVersion|21\.13\.6/,
      /makeYouTubeCPN|\bcpn\b/,
      /公式エンジン\/安定モード|独自プレイヤー\/直HLS/,
    ].forEach(pattern => {
      expect(combined).not.toMatch(pattern);
    });
  });

  it('keeps the b57-era direct HLS client order and request shape', () => {
    const playback = readProjectFile('src/playback.ts');
    const swift = readProjectFile('ios/MultiView/YouTubePlayer.swift');

    expect(playback).toContain("const youtubeIOSVersion = '21.17.3';");
    expect(playback).toContain("html5Preference: 'HTML5_PREF_WANTS'");
    expect(playback).toContain('export function extractPlayableYouTubeURL');
    expect(playback).toContain('stream.isHLS || !stream.isLive');
    // ライブ動画ID解決はタイムアウトでフルWebページへ落とさず、
    // モバイル→デスクトップUAで再試行する(=映像だけのHLS経路を維持する)。
    expect(playback).toContain('const userAgents = [mobileSafariUserAgent, desktopUserAgent];');
    expect(playback.indexOf("headerClientName: '5'")).toBeGreaterThanOrEqual(0);
    expect(playback.indexOf("headerClientName: '5'")).toBeLessThan(playback.indexOf("headerClientName: '3'"));

    expect(swift).toContain('label: "IOS"');
    expect(swift).toContain('"html5Preference": "HTML5_PREF_WANTS"');
    expect(swift).toContain('stream.isHLS || !stream.isLive');
    expect(swift.indexOf('label: "IOS"')).toBeGreaterThanOrEqual(0);
    expect(swift.indexOf('label: "IOS"')).toBeLessThan(swift.indexOf('label: "ANDROID"'));
  });

  it('keeps iOS-parity YouTube timeouts so HLS is not dropped to the ad-laden web page', () => {
    // FAILED METHODS — do not reintroduce (these made Android unstable while iOS was fine):
    //  - InnerTube /player request with an 8s timeout: too short, dropped live HLS and fell to
    //    the YouTube iframe. iOS (YouTubePlayer.swift) waits 12s per client.
    //  - @handle/live videoId resolution with a single 10s attempt that THREW on timeout:
    //    collapsed the whole stream to the full m.youtube.com web page (ads + YouTube UI,
    //    NOT 映像だけ). iOS waits up to URLSession default (~60s) with a mobileSafari UA +
    //    Accept header and never hard-fails to the page.
    const playback = readProjectFile('src/playback.ts');
    expect(playback).toContain('12000,'); // InnerTube /player per-client timeout (iOS parity)
    expect(playback).toContain('20000,'); // @handle/live resolution patience
    expect(playback).toContain("Accept: 'text/html,application/xhtml+xml"); // iOS-parity resolution header
    // the rejected aggressive /player timeout must not come back as the request cutoff
    expect(playback).not.toContain('        8000,\n      );');
  });

  it('requires YouTube chat fixes to exist on both Android JS and iOS Swift paths', () => {
    const chat = readProjectFile('src/chat.ts');
    const overlay = readProjectFile('src/DanmakuOverlay.tsx');
    const officialBridge = readProjectFile('src/YouTubeOfficialChatBridge.tsx');
    const swift = readProjectFile('ios/MultiView/YouTubePlayer.swift');

    expect(chat).toContain('const youtubeChatMinPollMs = 700');
    expect(chat).toContain('const youtubeChatMaxPollMs = 1600');
    expect(chat).toContain('export function youtubeChatPollDelayMs');
    expect(chat).toContain("?? 'emoji'");
    expect(overlay).toContain('const danmakuBacklogLimit = 20000');
    expect(overlay).toContain('YouTubeOfficialChatBridge');
    expect(overlay).toContain('duplicateWindowMs = 10000');
    expect(overlay).toContain('officialYouTubePrimaryMs = 10000');
    expect(overlay).toContain('laneReservationsRef');
    expect(overlay).toContain('Easing.linear');
    expect(overlay).toContain('isSuppressedYouTubeFallback');
    expect(officialBridge).toContain('youtubeOfficialChatObserverScript');
    expect(officialBridge).toContain('MutationObserver');
    expect(officialBridge).toContain('yt-live-chat-text-message-renderer');
    expect(officialBridge).toContain('yt-live-chat-paid-sticker-renderer');
    expect(officialBridge).not.toContain('yt-live-chat-viewer-engagement-message-renderer');
    expect(officialBridge).not.toContain('yt-live-chat-mode-change-message-renderer');
    expect(officialBridge).not.toContain('yt-live-chat-auto-mod-message-renderer');

    expect(swift).toContain('private let youtubeChatMinPollInterval: TimeInterval = 0.7');
    expect(swift).toContain('private let youtubeChatMaxPollInterval: TimeInterval = 1.6');
    expect(swift).toContain('private let youtubeChatBacklogLimit = 20000');
    expect(swift).toContain('var containsImage: Bool');
    expect(swift).toContain('let imageOnlyFallback = messageTokens.containsImage');
    expect(swift).toContain('private let youtubeChatDuplicateWindow: TimeInterval = 10');
    expect(swift).toContain('private let youtubeOfficialChatPrimaryWindow: TimeInterval = 10');
    expect(swift).toContain('officialChatActiveUntil');
    expect(swift).toContain('message.id.hasPrefix("yt-dom:")');
    expect(swift).toContain('startOfficialChatBridge(videoId: videoId)');
    expect(swift).toContain('youtubeOfficialChat');
    expect(swift).toContain('yt-live-chat-paid-sticker-renderer');
    expect(swift).not.toContain('yt-live-chat-viewer-engagement-message-renderer');
    expect(swift).not.toContain('yt-live-chat-mode-change-message-renderer');
    expect(swift).not.toContain('yt-live-chat-auto-mod-message-renderer');
    expect(swift).not.toContain('lastChatPollInterval');
    expect(swift).not.toContain('laneCapacity');
    expect(swift).not.toContain('burstSpacing');
  });

  it('does not infer YouTube viewer counts from page text snippets', () => {
    const app = readProjectFile('App.tsx');
    const viewerCount = readProjectFile('ios/MultiView/ViewerCount.swift');

    expect(app).toContain('concurrentViewers');
    expect(app).toContain('videoPrimaryInfoRenderer');
    expect(app).toContain('videoViewCountRenderer');
    expect(app).toContain('originalViewCount');
    expect(app).not.toContain('watching now');
    expect(app).not.toContain('人が視聴');
    expect(viewerCount).toContain('concurrentViewers');
    expect(viewerCount).toContain('videoPrimaryInfoRenderer');
    expect(viewerCount).toContain('videoViewCountRenderer');
    expect(viewerCount).toContain('originalViewCount');
    expect(viewerCount).not.toContain('watching now');
    expect(viewerCount).not.toContain('人が視聴');
  });
});

describe('YouTube HLS video-only extraction', () => {
  it('prefers hlsManifestUrl so playback is clean HLS (映像だけ), not the iframe/web page', () => {
    const result = extractPlayableYouTubeURL({
      videoDetails: {isLive: true, isLiveContent: true},
      streamingData: {
        hlsManifestUrl:
          'https://manifest.googlevideo.com/api/manifest/hls_variant/expire/1/file/index.m3u8',
        formats: [
          {url: 'https://progressive.example/muxed', mimeType: 'video/mp4; codecs="avc1.4d401f,mp4a.40.2"', height: 720, bitrate: 1_000},
        ],
      },
    });
    expect(result).not.toBeNull();
    expect(result?.isHLS).toBe(true);
    expect(result?.isLive).toBe(true);
    expect(result?.url).toContain('.m3u8');
  });

  it('returns null when there is no streamingData (drives iframe fallback, never the full web page)', () => {
    expect(extractPlayableYouTubeURL({})).toBeNull();
    expect(extractPlayableYouTubeURL({videoDetails: {isLive: true}})).toBeNull();
  });

  it('falls back to a muxed (audio+video) progressive format only when HLS is absent, skipping video-only tracks', () => {
    const result = extractPlayableYouTubeURL({
      videoDetails: {isLive: false, isLiveContent: true},
      streamingData: {
        formats: [
          // higher quality but video-only -> must be skipped (would play silent)
          {url: 'https://progressive.example/video-only-1080', mimeType: 'video/mp4; codecs="avc1.640028"', height: 1080, bitrate: 5_000},
          // muxed audio+video -> the only valid pick
          {url: 'https://progressive.example/muxed-720', mimeType: 'video/mp4; codecs="avc1.4d401f,mp4a.40.2"', height: 720, bitrate: 3_000},
        ],
      },
    });
    expect(result?.isHLS).toBe(false);
    expect(result?.url).toBe('https://progressive.example/muxed-720');
  });
});
