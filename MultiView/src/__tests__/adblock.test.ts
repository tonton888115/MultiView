import {adBlockDomains, isAdBlockedURL, platformAdBlockExtras} from '../adblock';

declare const __dirname: string;
const fs = require('fs') as {readFileSync(p: string, e: 'utf8'): string};
const path = require('path') as {resolve(...p: string[]): string; join(...p: string[]): string};
const projectRoot = path.resolve(__dirname, '..', '..');
const read = (rel: string) => fs.readFileSync(path.join(projectRoot, rel), 'utf8');

describe('web ad blocking (iOS WebAdBlocker parity)', () => {
  it('keeps the Android ad-domain list in sync with iOS WebAdBlocker.swift', () => {
    const swift = read('ios/MultiView/WebAdBlocker.swift');
    // iOS の if-domain に列挙された全ドメインが Android 側にも存在すること。
    expect(adBlockDomains.length).toBeGreaterThanOrEqual(14);
    adBlockDomains.forEach(domain => {
      expect(swift).toContain(`"${domain}"`);
    });
    // 動画広告の要 (Google IMA SDK) が必ず含まれること。
    expect(adBlockDomains).toContain('imasdk.googleapis.com');
    expect(adBlockDomains).toContain('doubleclick.net');
  });

  it('blocks ad domains and their subdomains but allows real stream hosts', () => {
    expect(isAdBlockedURL('https://imasdk.googleapis.com/js/sdkloader/ima3.js')).toBe(true);
    expect(isAdBlockedURL('https://static.doubleclick.net/x')).toBe(true);
    expect(isAdBlockedURL('https://pagead2.googlesyndication.com/x')).toBe(true);
    // 配信ホストは絶対に遮断しない。
    expect(isAdBlockedURL('https://live.nicovideo.jp/watch/lv1')).toBe(false);
    expect(isAdBlockedURL('https://kick.com/foo')).toBe(false);
    expect(isAdBlockedURL('https://www.youtube.com/watch?v=x')).toBe(false);
    expect(isAdBlockedURL('https://usher.ttvnw.net/api/channel/hls/foo.m3u8')).toBe(false);
    expect(isAdBlockedURL(null)).toBe(false);
    expect(isAdBlockedURL('not a url')).toBe(false);
  });

  it('injects niconico popup blocking and the kick/twitch touch shield like iOS', () => {
    expect(platformAdBlockExtras('niconico')).toContain('快適視聴');
    expect(platformAdBlockExtras('kick')).toContain('pointer-events:none');
    expect(platformAdBlockExtras('twitch')).toContain('pointer-events:none');
    expect(platformAdBlockExtras('youtube')).toBe('');
    expect(platformAdBlockExtras('twitcasting')).toBe('');
  });
});
