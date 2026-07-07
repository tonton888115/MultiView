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
    'src/players/StreamPlayer.tsx',
    'src/players/NiconicoNativePlayer.tsx',
    'src/players/TwitcastingNativePlayer.tsx',
    'src/components/TabButton.tsx',
    'src/components/Pill.tsx',
    'src/components/PlayerBadge.tsx',
    'src/components/VolumeOverlay.tsx',
    'src/components/ViewerCountBadge.tsx',
    'src/components/settingsRows.tsx',
    'src/components/sharedStyles.ts',
    'src/screens/SourceBrowser.tsx',
    'src/screens/HandoffModal.tsx',
    'src/screens/AddStreamModal.tsx',
    'src/screens/FocusModal.tsx',
    'src/screens/SettingsScreen.tsx',
    'src/useAutoHidingChrome.ts',
    'src/platforms.ts',
    'src/playback.ts',
    'src/viewerCount.ts',
    'src/webInject.ts',
    'src/network.ts',
    'src/types.ts',
    'ios/MultiView/BrowserUserAgent.swift',
    'ios/MultiView/YouTubePlayer.swift',
    'src/AnimatedEmoteImage.tsx',
    'src/YouTubeOfficialChatBridge.tsx',
    'android/app/src/main/java/com/multiview/AnimatedImageView.kt',
    'android/app/src/main/java/com/multiview/MultiViewPackage.kt',
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

  it('never collapses YouTube to the full web page, even when resolution fully fails', () => {
    // FAILED METHOD — do not reintroduce: when @handle/live videoId resolution returned null,
    // resolveYouTube used to return { kind: 'web', label: 'YouTube Web' } which loaded the full
    // m.youtube.com watch page (title/ads/charm) in a WebView — the exact thing the user rejects.
    // The contract now: YouTube must NEVER render the full web page. ID未解決はクリーンな
    // プレースホルダ(再試行)に落とし、StreamPlayer が静かに HLS への昇格を粘る。
    const playback = readProjectFile('src/playback.ts');
    const streamPlayer = readProjectFile('src/players/StreamPlayer.tsx');
    expect(playback).not.toContain("label: 'YouTube Web'");
    expect(playback).toContain("status: '映像取得中'"); // videoId 未解決のクリーンなプレースホルダ
    // 解決例外時も YouTube だけは Web フォールバック URL を設定しない
    // (resolvePlaybackSource は reject しないため、ガードは playback.ts 側にある)。
    expect(playback).toContain("stream.platform === 'youtube' ? undefined : webStreamURL(stream)");
    // 取得中/iframe に留まったらバックグラウンドで native HLS へ昇格を粘る。
    expect(streamPlayer).toContain('youtubeRetryRef');
  });

  it('keeps the native first-frame event used by the missing-video watchdog', () => {
    const nativePlayer = readProjectFile('android/app/src/main/java/com/multiview/NativeHlsPlayerView.kt');
    expect(nativePlayer).toContain('override fun onRenderedFirstFrame()');
    expect(nativePlayer).toContain('emit("firstFrame", "rendered")');
    expect(nativePlayer).toContain('LifecycleEventListener');
    expect(nativePlayer).toContain('override fun onHostResume()');
    expect(nativePlayer).toContain('override fun onSizeChanged(');
    expect(nativePlayer).toContain('scheduleVideoOutputRebind()');
    expect(nativePlayer).toContain('!textureView.isAvailable');
    expect(nativePlayer).toContain('exoPlayer.clearVideoTextureView(textureView)');
    expect(nativePlayer).toContain('exoPlayer.setVideoTextureView(textureView)');
  });

  it('requires YouTube chat fixes to exist on both Android JS and iOS Swift paths', () => {
    const chat = readProjectFile('src/chat.ts');
    const overlay = readProjectFile('src/DanmakuOverlay.tsx');
    const queue = readProjectFile('src/danmakuQueue.ts');
    const animatedEmote = readProjectFile('src/AnimatedEmoteImage.tsx');
    const officialBridge = readProjectFile('src/YouTubeOfficialChatBridge.tsx');
    const androidAnimatedImage = readProjectFile('android/app/src/main/java/com/multiview/AnimatedImageView.kt');
    const androidPackage = readProjectFile('android/app/src/main/java/com/multiview/MultiViewPackage.kt');
    const swift = readProjectFile('ios/MultiView/YouTubePlayer.swift');

    expect(chat).toContain('const youtubeChatMinPollMs = 700');
    expect(chat).toContain('const youtubeChatMaxPollMs = 1600');
    expect(chat).toContain('export function youtubeChatPollDelayMs');
    expect(chat).toContain("?? 'emoji'");
    expect(overlay).toContain('YouTubeOfficialChatBridge');
    expect(overlay).toContain('AnimatedEmoteImage');
    expect(overlay).toContain('officialYouTubePrimaryMs = 10000');
    expect(overlay).toContain('laneReservationsRef');
    expect(overlay).toContain('Easing.linear');
    expect(overlay).toContain('isSuppressedYouTubeFallback');
    expect(overlay).toContain('opacity: settings.danmakuOpacity');
    expect(overlay).toContain("color: '#fff'");
    expect(overlay).not.toContain('rgba(255,255,255,${settings.danmakuOpacity})');
    expect(overlay).toContain('zIndex: 12');
    expect(overlay).toContain('elevation: 12');
    expect(overlay).toContain('const showDanmaku = settings.showDanmaku');
    expect(overlay).not.toContain('if (!settings.showChat || !settings.showDanmaku)');
    expect(queue).toContain('const duplicateWindowMs = 10000');
    expect(queue).toContain('return settings.showDanmaku');
    expect(queue).toContain('class DanmakuEventQueue');
    expect(queue).toContain('this.head += 1');
    expect(queue).not.toContain('.shift(');
    expect(animatedEmote).toContain("requireNativeComponent<NativeAnimatedImageProps>('MVAnimatedImage')");
    expect(androidAnimatedImage).toContain('setAutoPlayAnimations(true)');
    expect(androidAnimatedImage).toContain('Fresco.newDraweeControllerBuilder()');
    expect(androidPackage).toContain('AnimatedImageManager()');
    expect(officialBridge).toContain('youtubeOfficialChatObserverScript');
    expect(officialBridge).toContain('MutationObserver');
    expect(officialBridge).toContain('yt-live-chat-text-message-renderer');
    expect(officialBridge).toContain('yt-live-chat-paid-sticker-renderer');
    expect(officialBridge).toContain('yt-live-chat-donation-announcement-renderer');
    expect(officialBridge).toContain("element.__mvFallbackChatID = 'fallback:'");
    expect(officialBridge).not.toContain("querySelectorAll('#sticker img, #content img.emoji')");
    expect(officialBridge).not.toContain('yt-live-chat-viewer-engagement-message-renderer');
    expect(officialBridge).not.toContain('yt-live-chat-mode-change-message-renderer');
    expect(officialBridge).not.toContain('yt-live-chat-auto-mod-message-renderer');

    expect(swift).toContain('private let youtubeChatMinPollInterval: TimeInterval = 0.7');
    expect(swift).toContain('private let youtubeChatMaxPollInterval: TimeInterval = 1.6');
    expect(swift).toContain('var containsImage: Bool');
    expect(swift).toContain('let imageOnlyFallback = messageTokens.containsImage');
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
    // Android の同接数ロジックは App.tsx から src/viewerCount.ts (フェッチ/パース) と
    // src/webInject.ts (WebView 注入スクレイパ) へ移設された。
    const app = readProjectFile('src/viewerCount.ts') + '\n' + readProjectFile('src/webInject.ts');
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

  it('documents the iOS legacy showChat setting as the native danmaku toggle', () => {
    const models = readProjectFile('ios/MultiView/Models.swift');
    const screens = readProjectFile('ios/MultiView/Screens.swift');
    const swift = readProjectFile('ios/MultiView/YouTubePlayer.swift');

    expect(models).toContain('iOS legacy naming');
    expect(screens).toContain('cell.textLabel?.text = "弾幕を表示"');
    expect(screens).toContain('AppState.shared.settings.showChat');
    expect(swift).toContain('guard settings.showChat else { return }');
    expect(swift).toContain('guard !isStopped, settings.showChat, pendingChatHead < pendingChatMessages.count else { return }');
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
