import React, {useCallback, useEffect, useRef, useState} from 'react';
import {StyleSheet, Text, View} from 'react-native';
import {subscribeGiftEvents, type GiftEvent} from './giftEvents';
import type {AppSettings, PlatformId, StreamItem} from './types';

const maxGiftBanners = 3;
const giftVisibleMs = 4500;

const platformAccent: Record<PlatformId, string> = {
  kick: '#53fc18',
  twitch: '#9146ff',
  youtube: '#ff3030',
  niconico: '#ff8a20',
  twitcasting: '#00a6ef',
};

type ActiveGift = GiftEvent & {key: string};

export function GiftOverlay({stream, settings}: {stream: StreamItem; settings: AppSettings}) {
  const [banners, setBanners] = useState<ActiveGift[]>([]);
  const timersRef = useRef<Array<ReturnType<typeof setTimeout>>>([]);
  const giftSoundEnabledRef = useRef(settings.giftSoundEnabled);
  giftSoundEnabledRef.current = settings.giftSoundEnabled;

  const clearTimers = useCallback(() => {
    timersRef.current.forEach(timer => clearTimeout(timer));
    timersRef.current = [];
  }, []);

  useEffect(() => {
    clearTimers();
    setBanners([]);
    if (!settings.showGiftEffects) {
      return;
    }
    const unsubscribe = subscribeGiftEvents(stream.id, event => {
      if (giftSoundEnabledRef.current) {
        playGiftCue();
      }
      const key = `${event.id}:${event.createdAt}:${Math.random().toString(36).slice(2)}`;
      setBanners(current => [{...event, key}, ...current].slice(0, maxGiftBanners));
      const timer = setTimeout(() => {
        setBanners(current => current.filter(banner => banner.key !== key));
        timersRef.current = timersRef.current.filter(current => current !== timer);
      }, giftVisibleMs);
      timersRef.current.push(timer);
    });
    return () => {
      unsubscribe();
      clearTimers();
    };
  }, [clearTimers, settings.showGiftEffects, stream.id]);

  if (!settings.showGiftEffects) {
    return null;
  }

  return (
    <View pointerEvents="none" style={styles.overlay}>
      {banners.map(banner => {
        const accent = platformAccent[banner.platform];
        const title = banner.author ? `${banner.author} / ${banner.headline}` : banner.headline;
        return (
          <View key={banner.key} style={[styles.banner, {borderLeftColor: accent, borderColor: `${accent}88`}]}>
            <Text numberOfLines={1} style={styles.title}>
              {title}
            </Text>
            <Text numberOfLines={2} style={styles.message}>
              {banner.text}
            </Text>
          </View>
        );
      })}
    </View>
  );
}

export function playGiftCue(): void {
  // TODO(sound): no RN audio dep yet — do NOT add any npm/native dependency.
}

const styles = StyleSheet.create({
  overlay: {
    position: 'absolute',
    top: 8,
    right: 0,
    left: 0,
    zIndex: 16,
    elevation: 16,
    alignItems: 'center',
  },
  banner: {
    width: '90%',
    maxWidth: 640,
    minHeight: 54,
    marginBottom: 6,
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderRadius: 8,
    borderWidth: 1,
    borderLeftWidth: 5,
    backgroundColor: 'rgba(5, 7, 10, 0.82)',
  },
  title: {
    color: '#fff',
    fontSize: 13,
    fontWeight: '900',
    textShadowColor: 'rgba(0,0,0,0.95)',
    textShadowRadius: 3,
    textShadowOffset: {width: 1, height: 1},
    includeFontPadding: false,
  },
  message: {
    marginTop: 3,
    color: 'rgba(255,255,255,0.86)',
    fontSize: 12,
    fontWeight: '700',
    lineHeight: 16,
    textShadowColor: 'rgba(0,0,0,0.9)',
    textShadowRadius: 2,
    textShadowOffset: {width: 1, height: 1},
    includeFontPadding: false,
  },
});
