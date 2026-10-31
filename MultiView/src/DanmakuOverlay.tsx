import React, {memo, useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {Animated, Easing, Image, StyleSheet, Text, View, type LayoutChangeEvent} from 'react-native';
import {estimateTokenWidth, textFromTokens, textTokens} from './danmaku';
import {startChatClient} from './chat';
import {YouTubeOfficialChatBridge} from './YouTubeOfficialChatBridge';
import {giftEventFromChatEvent, publishGiftEvent} from './giftEvents';
import type {AppSettings, ChatEvent, DanmakuToken, StreamItem} from './types';

const danmakuBacklogLimit = 20000;
const duplicateWindowMs = 10000;
const officialYouTubePrimaryMs = 10000;
// 画面外へ流れ切った弾幕の削除はまとめて行う(1件ごとの再描画を避ける)。
const removalFlushMs = 120;

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

type Metrics = {
  width: number;
  height: number;
  fontSize: number;
  lineHeight: number;
  laneCount: number;
};

// チャット接続や流し込み処理は「レイアウト/設定が変わるたびに作り直さない」ことが重要。
// 旧実装は onLayout や設定変更のたびに enqueue 関数が作り直され、それに依存する
// useEffect がチャット接続を切断→再接続し、待機中/表示中の弾幕も消していた
// (起動直後は onLayout で必ず1回、設定画面のトグルでも全配信が再接続)。
// ここでは寸法と設定を ref で読み、接続は配信と表示ON/OFFが変わった時だけ張り直す。
export const DanmakuOverlay = memo(function DanmakuOverlay({stream, settings}: {stream: StreamItem; settings: AppSettings}) {
  const [layout, setLayout] = useState<Layout>({width: 0, height: 0});
  const [visible, setVisible] = useState<VisibleItem[]>([]);
  const queueRef = useRef<ChatEvent[]>([]);
  // 表示中の弾幕は ref を正とし、同じ drain サイクル内のレーン選択でも最新を参照する。
  const visibleRef = useRef<VisibleItem[]>([]);
  const laneReservationsRef = useRef<LaneReservation[]>([]);
  const laneCursorRef = useRef(0);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const removalTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pendingRemovalsRef = useRef<Set<string>>(new Set());
  const recentFingerprintsRef = useRef<Map<string, number>>(new Map());
  const officialYouTubeActiveUntilRef = useRef(0);
  const settingsRef = useRef(settings);
  settingsRef.current = settings;
  const streamIdRef = useRef(stream.id);
  streamIdRef.current = stream.id;

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
  const metricsRef = useRef<Metrics>({width: 0, height: 0, fontSize, lineHeight, laneCount});
  metricsRef.current = {width: layout.width, height: layout.height, fontSize, lineHeight, laneCount};

  const publishVisible = useCallback((next: VisibleItem[]) => {
    visibleRef.current = next;
    setVisible(next);
  }, []);

  const flushRemovals = useCallback(() => {
    removalTimerRef.current = null;
    const keys = pendingRemovalsRef.current;
    if (keys.size === 0) {
      return;
    }
    const next = visibleRef.current.filter(item => !keys.has(item.key));
    keys.clear();
    publishVisible(next);
  }, [publishVisible]);

  const scheduleRemoval = useCallback(
    (key: string) => {
      pendingRemovalsRef.current.add(key);
      if (!removalTimerRef.current) {
        removalTimerRef.current = setTimeout(flushRemovals, removalFlushMs);
      }
    },
    [flushRemovals],
  );

  useEffect(() => {
    laneReservationsRef.current = [];
    laneCursorRef.current = 0;
  }, [laneCount, layout.width, layout.height]);

  const pickLane = useCallback((now: number, width: number, lanes: number): number => {
    const fronts = Array.from({length: lanes}, () => Number.NEGATIVE_INFINITY);
    const startX = width + 12;
    const activeReservations = laneReservationsRef.current.filter(
      reservation => reservation.lane >= 0
        && reservation.lane < lanes
        && now - reservation.startedAt <= reservation.duration,
    );
    laneReservationsRef.current = activeReservations;
    const addFront = (lane: number, front: number) => {
      fronts[lane] = Math.max(fronts[lane] ?? Number.NEGATIVE_INFINITY, front);
    };
    for (const item of visibleRef.current) {
      if (item.lane < 0 || item.lane >= lanes) {
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
    const clearThreshold = width - 36;
    for (let offset = 0; offset < lanes; offset += 1) {
      const candidate = (laneCursorRef.current + offset) % lanes;
      if ((fronts[candidate] ?? Number.NEGATIVE_INFINITY) < clearThreshold) {
        return candidate;
      }
    }
    // 全レーンが埋まっていても捨てない(Dr.Maggot 方式): 先頭が最も左まで進んだレーンへ重ねる。
    let furthestLane = 0;
    for (let lane = 1; lane < lanes; lane += 1) {
      if ((fronts[lane] ?? Number.NEGATIVE_INFINITY) < (fronts[furthestLane] ?? Number.NEGATIVE_INFINITY)) {
        furthestLane = lane;
      }
    }
    return furthestLane;
  }, []);

  const reserveLane = useCallback(
    (lane: number, now: number, widthEstimate: number, duration: number, width: number, lanes: number) => {
      const startX = width + 12;
      const endX = -widthEstimate - 12;
      laneReservationsRef.current = laneReservationsRef.current
        .filter(reservation => now - reservation.startedAt <= reservation.duration && reservation.lane >= 0 && reservation.lane < lanes)
        .concat({lane, widthEstimate, startedAt: now, duration, startX, endX});
    },
    [],
  );

  const emitNow = useCallback(
    (event: ChatEvent): boolean => {
      const currentSettings = settingsRef.current;
      const metrics = metricsRef.current;
      const text = event.text.trim();
      if (!text && !event.superInfo) {
        return true;
      }
      if (currentSettings.danmakuMaxLength > 0 && text.length > currentSettings.danmakuMaxLength) {
        return true;
      }
      if (metrics.width <= 0 || metrics.height <= 0) {
        return false;
      }
      const tokens = currentSettings.showEmotes ? event.tokens : textTokens(textFromTokens(event.tokens));
      const widthEstimate = estimateTokenWidth(tokens, metrics.fontSize);
      const travel = metrics.width + widthEstimate + 36;
      const pixelsPerSecond = Math.max(35, metrics.width * currentSettings.danmakuSpeed);
      const duration = Math.max(250, Math.round((travel / pixelsPerSecond) * 1000));
      const now = Date.now();
      const lane = pickLane(now, metrics.width, metrics.laneCount);
      laneCursorRef.current = (lane + 1) % metrics.laneCount;
      reserveLane(lane, now, widthEstimate, duration, metrics.width, metrics.laneCount);
      const key = `${event.id}:${event.createdAt}:${Math.random()}`;
      const x = new Animated.Value(metrics.width + 12);
      const item: VisibleItem = {
        key,
        event,
        tokens,
        lane,
        x,
        fontSize: metrics.fontSize,
        lineHeight: metrics.lineHeight,
        widthEstimate,
        startedAt: now,
        duration,
      };
      publishVisible([...visibleRef.current, item]);
      Animated.timing(x, {
        toValue: -widthEstimate - 12,
        duration,
        easing: Easing.linear,
        useNativeDriver: true,
      }).start(() => scheduleRemoval(key));
      return true;
    },
    [pickLane, publishVisible, reserveLane, scheduleRemoval],
  );

  const scheduleDrain = useCallback(() => {
    if (timerRef.current) {
      return;
    }
    const drain = () => {
      timerRef.current = null;
      let consumed = 0;
      const maxBurst = Math.max(5, metricsRef.current.laneCount * 5);
      while (queueRef.current.length > 0 && consumed < maxBurst) {
        const next = queueRef.current[0];
        if (isSuppressedYouTubeFallback(next, officialYouTubeActiveUntilRef.current)) {
          queueRef.current.shift();
          continue;
        }
        if (!emitNow(next)) {
          break;
        }
        queueRef.current.shift();
        consumed += 1;
      }
      if (queueRef.current.length > 0) {
        const {width, height} = metricsRef.current;
        const waitMs = width <= 0 || height <= 0 ? 120 : 8;
        timerRef.current = setTimeout(drain, waitMs);
      }
    };
    timerRef.current = setTimeout(drain, 16);
  }, [emitNow]);

  const enqueueEvent = useCallback(
    (event: ChatEvent) => {
      if (isOfficialYouTubeEvent(event)) {
        officialYouTubeActiveUntilRef.current = Date.now() + officialYouTubePrimaryMs;
        queueRef.current = queueRef.current.filter(
          queued => !isSuppressedYouTubeFallback(queued, officialYouTubeActiveUntilRef.current),
        );
      } else if (isSuppressedYouTubeFallback(event, officialYouTubeActiveUntilRef.current)) {
        return;
      }
      if (isRecentDuplicate(event, recentFingerprintsRef.current)) {
        return;
      }
      queueRef.current.push(event);
      if (queueRef.current.length > danmakuBacklogLimit) {
        queueRef.current.splice(0, queueRef.current.length - danmakuBacklogLimit);
      }
      const giftEvent = giftEventFromChatEvent(streamIdRef.current, event);
      if (giftEvent) {
        publishGiftEvent(streamIdRef.current, giftEvent);
      }
      scheduleDrain();
    },
    [scheduleDrain],
  );
  const ignoreStatus = useCallback(() => undefined, []);

  const chatEnabled = settings.showChat && settings.showDanmaku;
  useEffect(() => {
    if (!chatEnabled) {
      return;
    }
    const recentFingerprints = recentFingerprintsRef.current;
    const pendingRemovals = pendingRemovalsRef.current;
    const client = startChatClient(stream, settingsRef.current, enqueueEvent, ignoreStatus);
    return () => {
      client.stop();
      // 先にアニメーションを止める(終了コールバックが削除予約を積むので、その後で片付ける)。
      visibleRef.current.forEach(item => item.x.stopAnimation());
      queueRef.current = [];
      laneReservationsRef.current = [];
      recentFingerprints.clear();
      pendingRemovals.clear();
      officialYouTubeActiveUntilRef.current = 0;
      if (timerRef.current) {
        clearTimeout(timerRef.current);
        timerRef.current = null;
      }
      if (removalTimerRef.current) {
        clearTimeout(removalTimerRef.current);
        removalTimerRef.current = null;
      }
      publishVisible([]);
    };
  }, [chatEnabled, enqueueEvent, ignoreStatus, publishVisible, stream]);

  const onLayout = useCallback((event: LayoutChangeEvent) => {
    const {width, height} = event.nativeEvent.layout;
    setLayout(current => (current.width === width && current.height === height ? current : {width, height}));
  }, []);

  if (!chatEnabled) {
    return null;
  }

  return (
    <View pointerEvents="none" style={styles.overlay} onLayout={onLayout}>
      {visible.map(item => (
        <DanmakuItem key={item.key} item={item} opacity={settings.danmakuOpacity} />
      ))}
      {stream.platform === 'youtube' && (
        <YouTubeOfficialChatBridge stream={stream} onEvent={enqueueEvent} onStatus={ignoreStatus} />
      )}
    </View>
  );
});

// 1件ずつ memo して、弾幕の追加/削除のたびに流れている全件を描き直さない。
const DanmakuItem = memo(function DanmakuItem({item, opacity}: {item: VisibleItem; opacity: number}) {
  const textColor = `rgba(255,255,255,${opacity})`;
  return (
    <Animated.View
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
            style={[styles.text, {fontSize: item.fontSize, lineHeight: item.lineHeight, color: textColor}]}>
            {token.text}
          </Text>
        ),
      )}
    </Animated.View>
  );
});

function isRecentDuplicate(event: ChatEvent, recent: Map<string, number>): boolean {
  const now = Date.now();
  for (const [key, timestamp] of recent) {
    if (now - timestamp > duplicateWindowMs) {
      recent.delete(key);
    }
  }
  const key = eventFingerprint(event);
  if (recent.has(key)) {
    return true;
  }
  recent.set(key, now);
  return false;
}

function eventFingerprint(event: ChatEvent): string {
  if (event.platform !== 'youtube') {
    return [event.platform, event.id].join('\u001f');
  }
  const author = normalizeFingerprintText(event.author ?? '').toLowerCase();
  const visibleText = normalizeFingerprintText(event.text === 'emoji' ? textFromTokens(event.tokens) : event.text);
  const superInfo = normalizeFingerprintText(event.superInfo ?? '');
  if (visibleText && visibleText !== 'emoji') {
    return [event.platform, author, visibleText, superInfo].join('\u001f');
  }
  const tokenKey = event.tokens
    .map(token => (token.kind === 'image' ? `img:${token.url}:${token.alt ?? ''}` : `txt:${normalizeFingerprintText(token.text)}`))
    .join('|');
  return [event.platform, author, visibleText || 'emoji', superInfo, tokenKey].join('\u001f');
}

function normalizeFingerprintText(value: string): string {
  return value.replace(/\s+/g, ' ').trim();
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
});
