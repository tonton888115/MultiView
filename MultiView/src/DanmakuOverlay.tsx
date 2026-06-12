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
};

type LaneState = {
  nextAvailableAt: number;
  lastUsedAt: number;
};

export function DanmakuOverlay({stream, settings}: {stream: StreamItem; settings: AppSettings}) {
  const [layout, setLayout] = useState<Layout>({width: 0, height: 0});
  const [visible, setVisible] = useState<VisibleItem[]>([]);
  const [status, setStatus] = useState('');
  const queueRef = useRef<ChatEvent[]>([]);
  const laneStatesRef = useRef<LaneState[]>([]);
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

  const removeVisible = useCallback((key: string) => {
    setVisible(current => current.filter(item => item.key !== key));
  }, []);

  const normalizeLaneStates = useCallback(() => {
    const lanes = laneStatesRef.current;
    while (lanes.length < laneCount) {
      lanes.push({nextAvailableAt: 0, lastUsedAt: 0});
    }
    if (lanes.length > laneCount) {
      lanes.length = laneCount;
    }
  }, [laneCount]);

  useEffect(() => {
    normalizeLaneStates();
  }, [normalizeLaneStates]);

  const pickReadyLane = useCallback(
    (now: number): number | null => {
      normalizeLaneStates();
      const ready = laneStatesRef.current
        .map((state, lane) => ({lane, state}))
        .filter(item => item.state.nextAvailableAt <= now);
      if (ready.length === 0) {
        return null;
      }
      const oldest = Math.min(...ready.map(item => item.state.lastUsedAt));
      const candidates = ready.filter(item => item.state.lastUsedAt <= oldest + 120);
      return candidates[Math.floor(Math.random() * candidates.length)]?.lane ?? ready[0].lane;
    },
    [normalizeLaneStates],
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
      const travel = layout.width + widthEstimate + 32;
      const pixelsPerSecond = Math.max(35, layout.width * currentSettings.danmakuSpeed);
      const duration = Math.max(4500, Math.round((travel / pixelsPerSecond) * 1000));
      const now = Date.now();
      const lane = pickReadyLane(now);
      if (lane == null) {
        return false;
      }
      const holdMs = Math.min(2600, Math.max(380, Math.round((widthEstimate / pixelsPerSecond) * 1000 + 260)));
      laneStatesRef.current[lane] = {
        nextAvailableAt: now + holdMs,
        lastUsedAt: now,
      };
      const key = `${event.id}:${event.createdAt}:${Math.random()}`;
      const x = new Animated.Value(layout.width + 12);
      const item: VisibleItem = {key, event, tokens, lane, x, fontSize, lineHeight};
      setVisible(current => [...current, item]);
      Animated.timing(x, {
        toValue: -widthEstimate - 24,
        duration,
        useNativeDriver: true,
      }).start(() => removeVisible(key));
      return true;
    },
    [fontSize, layout.height, layout.width, lineHeight, pickReadyLane, removeVisible],
  );

  const scheduleDrain = useCallback(() => {
    if (timerRef.current) {
      return;
    }
    const drain = () => {
      timerRef.current = null;
      let consumed = 0;
      const maxBurst = Math.max(2, laneCount * 2);
      while (queueRef.current.length > 0 && consumed < maxBurst) {
        const next = queueRef.current[0];
        if (!emitNow(next)) {
          break;
        }
        queueRef.current.shift();
        consumed += 1;
      }
      if (queueRef.current.length > 0) {
        normalizeLaneStates();
        const nextReadyAt = Math.min(...laneStatesRef.current.map(state => state.nextAvailableAt));
        const waitMs = layout.width <= 0 || layout.height <= 0
          ? 120
          : Math.max(16, Math.min(180, nextReadyAt - Date.now()));
        timerRef.current = setTimeout(drain, waitMs);
      }
    };
    timerRef.current = setTimeout(drain, 16);
  }, [emitNow, laneCount, layout.height, layout.width, normalizeLaneStates]);

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
      setVisible([]);
    };
  }, [scheduleDrain, settings, stream]);

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
              top: item.lane * item.lineHeight + 4,
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
                    width: Math.max(22, item.fontSize * 1.45),
                    height: Math.max(22, item.fontSize * 1.45),
                  },
                ]}
              />
            ) : (
              <Text key={`${item.key}:txt:${index}`} style={[styles.text, {fontSize: item.fontSize, lineHeight: item.lineHeight}]}>
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
    paddingHorizontal: 6,
    borderRadius: 5,
    borderWidth: 1,
    borderColor: '#ffe46b',
    backgroundColor: 'rgba(255, 222, 80, 0.12)',
  },
  text: {
    color: 'rgba(255,255,255,0.96)',
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
