import React, {useCallback, useEffect, useRef, useState} from 'react';
import {NativeModules, StyleSheet, Text, View} from 'react-native';
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

export function shouldDisplayGiftOverlayEvent(event: GiftEvent, settings: AppSettings): boolean {
  if (event.platform !== 'niconico') {
    return settings.showGiftEffects;
  }
  if (event.kind === 'nicoad') {
    return settings.niconicoShowNicoad;
  }
  if (event.kind === 'notification') {
    return settings.niconicoShowNotification;
  }
  return settings.showGiftEffects && settings.niconicoShowGift;
}

// React.memo: 親プレイヤーの再レンダー毎に再構築しない(props は実変更時のみ変わる)。
export const GiftOverlay = React.memo(function GiftOverlay({
  stream,
  settings,
  active = true,
}: {
  stream: StreamItem;
  settings: AppSettings;
  active?: boolean;
}) {
  const [banners, setBanners] = useState<ActiveGift[]>([]);
  const timersRef = useRef<Array<ReturnType<typeof setTimeout>>>([]);
  const giftSoundEnabledRef = useRef(settings.giftSoundEnabled);
  giftSoundEnabledRef.current = settings.giftSoundEnabled;
  const settingsRef = useRef(settings);
  settingsRef.current = settings;
  // 視聴タブが背面の間は新規ギフト演出(表示と通知音)を捨てる。購読自体は保つ。
  const activeRef = useRef(active);
  activeRef.current = active;

  const clearTimers = useCallback(() => {
    timersRef.current.forEach(timer => clearTimeout(timer));
    timersRef.current = [];
  }, []);

  useEffect(() => {
    if (!active) {
      // 背面へ回ったら表示中のバナーとタイマーも畳んで再レンダーを止める。
      clearTimers();
      setBanners(current => (current.length > 0 ? [] : current));
    }
  }, [active, clearTimers]);

  useEffect(() => {
    clearTimers();
    setBanners([]);
    const unsubscribe = subscribeGiftEvents(stream.id, event => {
      if (!activeRef.current) {
        return;
      }
      if (!shouldDisplayGiftOverlayEvent(event, settingsRef.current)) {
        return;
      }
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
  }, [clearTimers, stream.id]);

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
});

export function playGiftCue(): void {
  try {
    NativeModules.GiftSound?.play?.();
  } catch {
    // Sound is best-effort; visual delivery must continue.
  }
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
