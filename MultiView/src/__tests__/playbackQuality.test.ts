import {effectiveQuality} from '../playback';
import {niconicoQuality} from '../niconico';
import {isCellular} from '../network';
import type {AppSettings} from '../types';

function settings(overrides: Partial<AppSettings> = {}): AppSettings {
  return {
    settingsVersion: 3,
    showChat: true,
    showDanmaku: true,
    showEmotes: true,
    showViewerCount: true,
    playAudio: true,
    autoFollowRaids: false,
    blockWebAds: true,
    youtubePreferIframe: false,
    youtubeStableBuffer: true,
    layoutMode: 'stacked',
    wifiQuality: 'high',
    mobileQuality: 'economy',
    danmakuFontSize: 20,
    danmakuSpeed: 0.13,
    danmakuOpacity: 0.9,
    danmakuMaxLines: 0,
    danmakuMaxLength: 0,
    niconicoLowLatency: false,
    showGiftEffects: true,
    giftSoundEnabled: true,
    niconicoShowGift: true,
    niconicoShowNicoad: true,
    niconicoShowNotification: true,
    autoEconomyOnManyStreams: true,
    platformOrder: ['kick', 'twitch', 'youtube', 'niconico', 'twitcasting'],
    ...overrides,
  };
}

describe('network-adaptive playback quality', () => {
  it('uses Wi-Fi quality on Wi-Fi', () => {
    expect(effectiveQuality(settings({wifiQuality: 'high'}), 1, 'wifi')).toBe('high');
    expect(effectiveQuality(settings({wifiQuality: 'economy'}), 1, 'wifi')).toBe('economy');
  });

  it('uses mobile quality on cellular', () => {
    expect(effectiveQuality(settings({wifiQuality: 'high', mobileQuality: 'economy'}), 1, 'cellular')).toBe('economy');
    expect(effectiveQuality(settings({wifiQuality: 'economy', mobileQuality: 'high'}), 1, 'cellular')).toBe('high');
  });

  it('uses the conservative mobile quality until Wi-Fi is confirmed', () => {
    const appSettings = settings({wifiQuality: 'high', mobileQuality: 'economy'});
    expect(effectiveQuality(appSettings, 1, 'none')).toBe('economy');
    expect(effectiveQuality(appSettings, 1, 'other')).toBe('economy');
  });

  it('auto economy at three streams overrides network quality', () => {
    const appSettings = settings({wifiQuality: 'high', mobileQuality: 'high', autoEconomyOnManyStreams: true});
    expect(effectiveQuality(appSettings, 3, 'wifi')).toBe('economy');
    expect(effectiveQuality(appSettings, 3, 'cellular')).toBe('economy');
  });

  it('defaults conservatively when network type is omitted', () => {
    expect(effectiveQuality(settings({wifiQuality: 'high', mobileQuality: 'economy'}), 1)).toBe('economy');
  });

  it('detects cellular only for the cellular network type', () => {
    expect(isCellular('cellular')).toBe(true);
    expect(isCellular('wifi')).toBe(false);
    expect(isCellular('other')).toBe(false);
    expect(isCellular('none')).toBe(false);
  });

  it('maps effective quality to Niconico session quality', () => {
    expect(niconicoQuality('economy')).toBe('low');
    expect(niconicoQuality('high')).toBe('abr');
  });
});
