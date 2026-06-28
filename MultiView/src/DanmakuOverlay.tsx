import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {Animated, Easing, Image, StyleSheet, Text, View} from 'react-native';
import {estimateTokenWidth, textFromTokens, textTokens} from './danmaku';
import {appendDanmakuEvent, consumeDanmakuEvent, DanmakuEventQueue, isDanmakuEnabled, isRecentDanmakuDuplicate} from './danmakuQueue';
import {startChatClient} from './chat';
import {YouTubeOfficialChatBridge} from './YouTubeOfficialChatBridge';
import {giftEventFromChatEvent, publishGiftEvent} from './giftEvents';
import type {AppSettings, ChatEvent, DanmakuToken, StreamItem} from './types';

const officialYouTubePrimaryMs = 10000;

type Layout = {
  width: number;
  height: number;
};

type VisibleItem = {
  key: string;
  event: ChatEvent;
  tokens: DanmakuToken[];
  lane: number;
  x: Animated.Value;
  fontSize: number;
  lineHeight: number;
  widthEstimate: number;
  startedAt: number;
  duration: number;
};

type LaneReservation = {
  lane: number;
  widthEstimate: number;
  startedAt: number;
  duration: number;
  startX: number;
  endX: number;
};

export function DanmakuOverlay({stream, settings}: {stream: StreamItem; settings: AppSettings}) {
  const [layout, setLayout] = useState<Layout>({width: 0, height: 0});
  const [visible, setVisible] = useState<VisibleItem[]>([]);
  const queueRef = useRef(new DanmakuEventQueue());
  const visibleRef = useRef<VisibleItem[]>([]);
  const laneReservationsRef = useRef<LaneReservation[]>([]);
  const laneCursorRef = useRef(0);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const scheduleDrainRef = useRef<() => void>(() => undefined);
  const recentEventsRef = useRef<Map<string, number>>(new Map());
  const officialYouTubeActiveUntilRef = useRef(0);
  const settingsRef = useRef(settings);
  settingsRef.current = settings;
  const showDanmaku = settings.showDanmaku;

  const fontSize = useMemo(() => scaledFontSize(settings.danmakuFontSize, layout.width), [layout.width, settings.danmakuFontSize]);
  const lineHeight = fontSize + 8;
  const laneCount = useMemo(() => {
    if (layout.height <= 0) {
      return 1;
    }
    return settings.danmakuMaxLines > 0
      ? Math.max(1, settings.danmakuMaxLines)
      : Math.max(1, Math.floor(layout.height / lineHeight));
  }, [layout.height, lineHeight, settings.danmakuMaxLines]);

  const updateVisible = useCallback((updater: (current: VisibleItem[]) => VisibleItem[]) => {
    setVisible(current => {
      const next = updater(current);
      visibleRef.current = next;
      return next;
    });
  }, []);

  const removeVisible = useCallback((key: string) => {
    updateVisible(current => current.filter(item => item.key !== key));
  }, [updateVisible]);

  useEffect(() => {
    laneReservationsRef.current = [];
    laneCursorRef.current = 0;
  }, [laneCount, layout.width, layout.height]);

  const pickLane = useCallback(
    (now: number): number => {
      const fronts = Array.from({length: laneCount}, () => Number.NEGATIVE_INFINITY);
      const startX = layout.width + 12;
      const activeReservations = laneReservationsRef.current.filter(
        reservation => reservation.lane >= 0
          && reservation.lane < laneCount
          && now - reservation.startedAt <= reservation.duration,
      );
      laneReservationsRef.current = activeReservations;
      const addFront = (lane: number, front: number) => {
        fronts[lane] = Math.max(fronts[lane] ?? Number.NEGATIVE_INFINITY, front);
      };
      for (const item of visibleRef.current) {
        if (item.lane < 0 || item.lane >= laneCount) {
          continue;
        }
        const progress = Math.max(0, Math.min(1, (now - item.startedAt) / item.duration));
        const currentX = startX + (-item.widthEstimate - 12 - startX) * progress;
        addFront(item.lane, currentX + item.widthEstimate);
      }
      for (const reservation of activeReservations) {
        const progress = Math.max(0, Math.min(1, (now - reservation.startedAt) / reservation.duration));
        const currentX = reservation.startX + (reservation.endX - reservation.startX) * progress;
        addFront(reservation.lane, currentX + reservation.widthEstimate);
      }
      const clearThreshold = layout.width - 36;
      for (let offset = 0; offset < laneCount; offset += 1) {
        const candidate = (laneCursorRef.current + offset) % laneCount;
        if ((fronts[candidate] ?? Number.NEGATIVE_INFINITY) < clearThreshold) {
          return candidate;
        }
      }
      let furthestLane = 0;
      for (let lane = 1; lane < laneCount; lane += 1) {
        if ((fronts[lane] ?? Number.NEGATIVE_INFINITY) < (fronts[furthestLane] ?? Number.NEGATIVE_INFINITY)) {
          furthestLane = lane;
        }
      }
      return furthestLane;
    },
    [laneCount, layout.width],
  );

  const reserveLane = useCallback(
    (lane: number, now: number, widthEstimate: number, duration: number) => {
      const startX = layout.width + 12;
      const endX = -widthEstimate - 12;
      laneReservationsRef.current = laneReservationsRef.current
        .filter(reservation => now - reservation.startedAt <= reservation.duration && reservation.lane >= 0 && reservation.lane < laneCount)
        .concat({lane, widthEstimate, startedAt: now, duration, startX, endX});
    },
    [laneCount, layout.width],
  );

  const emitNow = useCallback(
    (event: ChatEvent): boolean => {
      const currentSettings = settingsRef.current;
      const text = event.text.trim();
      if (!text && !event.superInfo) {
        return true;
      }
      if (currentSettings.danmakuMaxLength > 0 && text.length > currentSettings.danmakuMaxLength) {
        return true;
      }
      if (layout.width <= 0 || layout.height <= 0) {
        return false;
      }
      const tokens = currentSettings.showEmotes ? event.tokens : textTokens(textFromTokens(event.tokens));
      const widthEstimate = estimateTokenWidth(tokens, fontSize);
      const travel = layout.width + widthEstimate + 36;
      const pixelsPerSecond = Math.max(35, layout.width * currentSettings.danmakuSpeed);
      const duration = Math.max(250, Math.round((travel / pixelsPerSecond) * 1000));
      const now = Date.now();
      const lane = pickLane(now);
      laneCursorRef.current = (lane + 1) % laneCount;
      reserveLane(lane, now, widthEstimate, duration);
      const key = `${event.id}:${event.createdAt}:${Math.random()}`;
      const x = new Animated.Value(layout.width + 12);
      const item: VisibleItem = {key, event, tokens, lane, x, fontSize, lineHeight, widthEstimate, startedAt: now, duration};
      updateVisible(current => [...current, item]);
      Animated.timing(x, {
        toValue: -widthEstimate - 12,
        duration,
        easing: Easing.linear,
        useNativeDriver: true,
      }).start(() => removeVisible(key));
      return true;
    },
    [fontSize, laneCount, layout.height, layout.width, lineHeight, pickLane, removeVisible, reserveLane, updateVisible],
  );

  const scheduleDrain = useCallback(() => {
    if (timerRef.current) {
      return;
    }
    const drain = () => {
      timerRef.current = null;
      let consumed = 0;
      const maxBurst = Math.max(5, laneCount * 5);
      while (queueRef.current.length > 0 && consumed < maxBurst) {
        const next = queueRef.current.peek();
        if (!next) {
          break;
        }
        if (isSuppressedYouTubeFallback(next, officialYouTubeActiveUntilRef.current)) {
          consumeDanmakuEvent(queueRef.current);
          continue;
        }
        if (!emitNow(next)) {
          break;
        }
        consumeDanmakuEvent(queueRef.current);
        consumed += 1;
      }
      if (queueRef.current.length > 0) {
        const waitMs = layout.width <= 0 || layout.height <= 0
          ? 120
          : 8;
        timerRef.current = setTimeout(drain, waitMs);
      }
    };
    timerRef.current = setTimeout(drain, 16);
  }, [emitNow, laneCount, layout.height, layout.width]);
  scheduleDrainRef.current = scheduleDrain;

  const enqueueEvent = useCallback(
    (event: ChatEvent) => {
      if (isOfficialYouTubeEvent(event)) {
        officialYouTubeActiveUntilRef.current = Date.now() + officialYouTubePrimaryMs;
        queueRef.current.removeWhere(
          queued => isSuppressedYouTubeFallback(queued, officialYouTubeActiveUntilRef.current),
        );
      } else if (isSuppressedYouTubeFallback(event, officialYouTubeActiveUntilRef.current)) {
        return;
      }
      if (isRecentDanmakuDuplicate(event, recentEventsRef.current)) {
        return;
      }
      appendDanmakuEvent(queueRef.current, event);
      const giftEvent = giftEventFromChatEvent(stream.id, event);
      if (giftEvent) {
        publishGiftEvent(stream.id, giftEvent);
      }
      scheduleDrainRef.current();
    },
    [stream.id],
  );
  const ignoreStatus = useCallback(() => undefined, []);

  useEffect(() => {
    if (!showDanmaku) {
      return;
    }
    const queue = queueRef.current;
    const recentEvents = recentEventsRef.current;
    const client = startChatClient(
      stream,
      settingsRef.current,
      enqueueEvent,
      ignoreStatus,
    );
    return () => {
      client.stop();
      queue.clear();
      laneReservationsRef.current = [];
      recentEvents.clear();
      officialYouTubeActiveUntilRef.current = 0;
      if (timerRef.current) {
        clearTimeout(timerRef.current);
        timerRef.current = null;
      }
      updateVisible(() => []);
    };
  }, [enqueueEvent, ignoreStatus, showDanmaku, stream, updateVisible]);

  if (!isDanmakuEnabled(settings)) {
    return null;
  }

  return (
    <View
      pointerEvents="none"
      style={styles.overlay}
      onLayout={event => setLayout(event.nativeEvent.layout)}>
      {visible.map(item => (
        <Animated.View
          key={item.key}
          style={[
            styles.item,
            item.event.highlighted && styles.highlighted,
            {
              top: item.lane * item.lineHeight + 6,
              minHeight: item.lineHeight,
              opacity: settings.danmakuOpacity,
              transform: [{translateX: item.x}],
            },
          ]}>
          {item.tokens.map((token, index) =>
            token.kind === 'image' ? (
              <Image
                key={`${item.key}:img:${index}`}
                source={{uri: token.url}}
                resizeMode="contain"
                style={[
                  styles.emote,
                  {
                    width: Math.max(18, item.fontSize * 1.4),
                    height: Math.max(18, item.fontSize * 1.4),
                  },
                ]}
              />
            ) : (
              <Text
                key={`${item.key}:txt:${index}`}
                style={[styles.text, {fontSize: item.fontSize, lineHeight: item.lineHeight}]}>
                {token.text}
              </Text>
            ),
          )}
        </Animated.View>
      ))}
      {stream.platform === 'youtube' && (
        <YouTubeOfficialChatBridge stream={stream} onEvent={enqueueEvent} onStatus={ignoreStatus} />
      )}
    </View>
  );
}

function isOfficialYouTubeEvent(event: ChatEvent): boolean {
  return event.platform === 'youtube' && event.id.startsWith('yt-dom:');
}

function isSuppressedYouTubeFallback(event: ChatEvent, officialActiveUntil: number): boolean {
  return event.platform === 'youtube' && !isOfficialYouTubeEvent(event) && Date.now() < officialActiveUntil;
}

function scaledFontSize(base: number, width: number): number {
  if (width <= 0) {
    return base;
  }
  const scale = Math.min(1.8, Math.max(0.55, width / 340));
  return Math.round(base * scale);
}

const styles = StyleSheet.create({
  overlay: {
    position: 'absolute',
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
    zIndex: 12,
    elevation: 12,
    overflow: 'hidden',
  },
  item: {
    position: 'absolute',
    left: 0,
    maxWidth: 1200,
    flexDirection: 'row',
    alignItems: 'center',
    flexWrap: 'nowrap',
  },
  highlighted: {
    paddingHorizontal: 8,
    borderRadius: 4,
    borderWidth: 2,
    borderColor: '#ffe46b',
    backgroundColor: 'rgba(255, 222, 80, 0.12)',
  },
  text: {
    color: '#fff',
    fontWeight: '900',
    textShadowColor: 'rgba(0,0,0,0.95)',
    textShadowRadius: 3,
    textShadowOffset: {width: 1, height: 1},
    includeFontPadding: false,
  },
  emote: {
    marginHorizontal: 3,
  },
});
