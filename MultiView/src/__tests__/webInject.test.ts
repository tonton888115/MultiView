import {escapeForInjectedString, sourceBridgeScript, webFallbackScript} from '../webInject';
import type {PlatformId} from '../types';

const allPlatforms: PlatformId[] = ['kick', 'twitch', 'youtube', 'niconico', 'twitcasting'];

describe('webFallbackScript', () => {
  it('injects the YouTube viewer-count scraper only for youtube', () => {
    const youtube = webFallbackScript(true, 'youtube');
    expect(youtube).toContain('postYouTubeViewerCount');
    expect(youtube).toContain('ytInitialData');
    expect(youtube).toContain('setInterval(postYouTubeViewerCount, 5000);');
    // ytInitialData は YouTube 以外のページには存在しないため、
    // 他PFへは 5 秒ポーリング付きスクレイパを注入しない。
    allPlatforms.filter(platform => platform !== 'youtube').forEach(platform => {
      const script = webFallbackScript(true, platform);
      expect(script).not.toContain('postYouTubeViewerCount');
      expect(script).not.toContain('ytInitialData');
      // 広告/ポップアップ対策の tame() と MutationObserver 監視は全PFで維持する。
      expect(script).toContain('function tame()');
      expect(script).toContain('new MutationObserver(');
    });
  });

  it('keeps the twitcasting player focus loop', () => {
    const script = webFallbackScript(false, 'twitcasting');
    expect(script).toContain('focusTwitCastingPlayer');
    expect(script).toContain('setInterval(focusTwitCastingPlayer, 2000);');
  });

  it('keeps the volume/play bridge on every platform', () => {
    allPlatforms.forEach(platform => {
      const script = webFallbackScript(true, platform);
      expect(script).toContain('window.mvPlay=');
      expect(script).toContain('window.mvPause=');
      expect(script).toContain('window.mvSetVolume=');
    });
  });

  it('generates syntactically valid scripts for every platform and blockAds combination', () => {
    allPlatforms.forEach(platform => {
      [true, false].forEach(blockAds => {
        expect(() => new Function(webFallbackScript(blockAds, platform))).not.toThrow();
      });
    });
    expect(() => new Function(sourceBridgeScript)).not.toThrow();
  });
});

describe('escapeForInjectedString', () => {
  it('escapes quotes/backslashes and flattens newlines', () => {
    expect(escapeForInjectedString("a'b\\c\nd")).toBe("a\\'b\\\\c d");
    expect(escapeForInjectedString('line1\r\nline2')).toBe('line1 line2');
  });
});
