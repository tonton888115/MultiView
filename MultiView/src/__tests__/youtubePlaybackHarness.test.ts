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
    expect(playback).toContain('function extractPlayableYouTubeURL');
    expect(playback).toContain('stream.isHLS || !stream.isLive');
    expect(playback.indexOf("headerClientName: '5'")).toBeGreaterThanOrEqual(0);
    expect(playback.indexOf("headerClientName: '5'")).toBeLessThan(playback.indexOf("headerClientName: '3'"));

    expect(swift).toContain('label: "IOS"');
    expect(swift).toContain('"html5Preference": "HTML5_PREF_WANTS"');
    expect(swift).toContain('stream.isHLS || !stream.isLive');
    expect(swift.indexOf('label: "IOS"')).toBeGreaterThanOrEqual(0);
    expect(swift.indexOf('label: "IOS"')).toBeLessThan(swift.indexOf('label: "ANDROID"'));
  });

  it('requires YouTube chat fixes to exist on both Android JS and iOS Swift paths', () => {
    const chat = readProjectFile('src/chat.ts');
    const overlay = readProjectFile('src/DanmakuOverlay.tsx');
    const swift = readProjectFile('ios/MultiView/YouTubePlayer.swift');

    expect(chat).toContain('const youtubeChatMinPollMs = 700');
    expect(chat).toContain('const youtubeChatMaxPollMs = 1600');
    expect(chat).toContain('export function youtubeChatPollDelayMs');
    expect(chat).toContain("?? 'emoji'");
    expect(overlay).toContain('const danmakuBacklogLimit = 20000');

    expect(swift).toContain('private let youtubeChatMinPollInterval: TimeInterval = 0.7');
    expect(swift).toContain('private let youtubeChatMaxPollInterval: TimeInterval = 1.6');
    expect(swift).toContain('private let youtubeChatBacklogLimit = 20000');
    expect(swift).toContain('var containsImage: Bool');
    expect(swift).toContain('let imageOnlyFallback = messageTokens.containsImage');
  });
});
