import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {Animated, Image, StyleSheet, Text, View} from 'react-native';
import {estimateTokenWidth, textFromTokens, textTokens} from './danmaku';
import {startChatClient} from './chat';
import type {AppSettings, ChatEvent, DanmakuToken, StreamItem} from './types';

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

export function DanmakuOverlay({stream, settings}: {stream: StreamItem; settings: AppSettings}) {
  const [layout, setLayout] = useState<Layout>({width: 0, height: 0});
  const [visible, setVisible] = useState<VisibleItem[]>([]);
  const [status, setStatus] = useState('');
  const queueRef = useRef<ChatEvent[]>([]);
  const visibleRef = useRef<VisibleItem[]>([]);
  const laneCursorRef = useRef(0);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const settingsRef = useRef(settings);
  settingsRef.current = settings;

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

  const pickLane = useCallback(
    (now: number): number => {
      const fronts = Array.from({length: laneCount}, () => Number.NEGATIVE_INFINITY);
      const startX = layout.width + 12;
      for (const item of visibleRef.current) {
        if (item.lane < 0 || item.lane >= laneCount) {
          continue;
        }
        const progress = Math.max(0, Math.min(1, (now - item.startedAt) / item.duration));
        const currentX = startX + (-item.widthEstimate - 12 - startX) * progress;
        fronts[item.lane] = Math.max(fronts[item.lane], currentX + item.widthEstimate);
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
      laneCursorRef.current = lane + 1;
      const key = `${event.id}:${event.createdAt}:${Math.random()}`;
      const x = new Animated.Value(layout.width + 12);
      const item: VisibleItem = {key, event, tokens, lane, x, fontSize, lineHeight, widthEstimate, startedAt: now, duration};
      updateVisible(current => [...current, item]);
      Animated.timing(x, {
        toValue: -widthEstimate - 12,
        duration,
        useNativeDriver: true,
      }).start(() => removeVisible(key));
      return true;
    },
    [fontSize, layout.height, layout.width, lineHeight, pickLane, removeVisible, updateVisible],
  );

  const scheduleDrain = useCallback(() => {
    if (timerRef.current) {
      return;
    }
    const drain = () => {
      timerRef.current = null;
      let consumed = 0;
      const maxBurst = Math.max(3, laneCount * 3);
      while (queueRef.current.length > 0 && consumed < maxBurst) {
        const next = queueRef.current[0];
        if (!emitNow(next)) {
          break;
        }
        queueRef.current.shift();
        consumed += 1;
      }
      if (queueRef.current.length > 0) {
        const waitMs = layout.width <= 0 || layout.height <= 0
          ? 120
          : 16;
        timerRef.current = setTimeout(drain, waitMs);
      }
    };
    timerRef.current = setTimeout(drain, 16);
  }, [emitNow, laneCount, layout.height, layout.width]);

  useEffect(() => {
    if (!settings.showChat || !settings.showDanmaku) {
      return;
    }
    const client = startChatClient(
      stream,
      settings,
      event => {
        queueRef.current.push(event);
        if (queueRef.current.length > 5000) {
          queueRef.current.splice(0, queueRef.current.length - 5000);
        }
        scheduleDrain();
      },
      setStatus,
    );
    return () => {
      client.stop();
      queueRef.current = [];
      if (timerRef.current) {
        clearTimeout(timerRef.current);
        timerRef.current = null;
      }
      updateVisible(() => []);
    };
  }, [scheduleDrain, settings, stream, updateVisible]);

  if (!settings.showChat || !settings.showDanmaku) {
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
                style={[styles.text, {fontSize: item.fontSize, lineHeight: item.lineHeight, color: `rgba(255,255,255,${settings.danmakuOpacity})`}]}>
                {token.text}
              </Text>
            ),
          )}
        </Animated.View>
      ))}
      {!!status && (
        <View style={styles.status}>
          <Text style={styles.statusText} numberOfLines={1}>
            {status}
          </Text>
        </View>
      )}
    </View>
  );
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
    fontWeight: '900',
    textShadowColor: 'rgba(0,0,0,0.95)',
    textShadowRadius: 3,
    textShadowOffset: {width: 1, height: 1},
    includeFontPadding: false,
  },
  emote: {
    marginHorizontal: 3,
  },
  status: {
    position: 'absolute',
    top: 8,
    left: 8,
    maxWidth: '72%',
    minHeight: 22,
    paddingHorizontal: 8,
    borderRadius: 7,
    backgroundColor: 'rgba(5,7,10,0.62)',
    justifyContent: 'center',
  },
  statusText: {
    color: '#b8c6d8',
    fontSize: 10,
    fontWeight: '700',
  },
});
