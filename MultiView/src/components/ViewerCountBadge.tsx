import React, {useCallback, useEffect, useRef, useState} from 'react';
import {Animated, StyleSheet, Text} from 'react-native';
import type {StreamItem} from '../types';
import {fetchViewerCount} from '../viewerCount';
import {chromeAutoHideDelayMs} from '../useAutoHidingChrome';

export const ViewerCountBadge = React.memo(function ViewerCountBadge({
  stream,
  externalCount,
  visible,
  active = true,
}: {
  stream: StreamItem;
  externalCount?: number | null;
  visible: boolean;
  active?: boolean;
}) {
  const [count, setCount] = useState<number | null>(null);
  const opacity = useRef(new Animated.Value(0)).current;
  const inFlightRef = useRef(false);
  const hideTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const clearHideTimer = useCallback(() => {
    if (hideTimerRef.current) {
      clearTimeout(hideTimerRef.current);
      hideTimerRef.current = null;
    }
  }, []);

  const reveal = useCallback(() => {
    clearHideTimer();
    Animated.timing(opacity, {
      toValue: 1,
      duration: 140,
      useNativeDriver: true,
    }).start();
    hideTimerRef.current = setTimeout(() => {
      Animated.timing(opacity, {
        toValue: 0,
        duration: 520,
        useNativeDriver: true,
      }).start();
      hideTimerRef.current = null;
    }, chromeAutoHideDelayMs);
  }, [clearHideTimer, opacity]);

  useEffect(() => {
    if (externalCount != null && externalCount >= 0) {
      setCount(Math.round(externalCount));
      reveal();
    }
  }, [externalCount, reveal]);

  useEffect(() => {
    setCount(null);
    opacity.setValue(0);
    clearHideTimer();
  }, [clearHideTimer, opacity, stream.id]);

  useEffect(() => {
    if (visible && count != null && count >= 0) {
      reveal();
    }
  }, [count, reveal, visible]);

  useEffect(() => () => clearHideTimer(), [clearHideTimer]);

  useEffect(() => {
    if (!active) {
      // 視聴タブが背面の間は 30 秒ポーリングを止める。active 復帰でこの effect が
      // 再実行され、即時 refresh + インターバル再開になる。
      return;
    }
    let cancelled = false;
    const refresh = () => {
      if (inFlightRef.current) {
        return;
      }
      inFlightRef.current = true;
      fetchViewerCount(stream)
        .then(value => {
          if (!cancelled && value != null) {
            setCount(value);
            reveal();
          }
        })
        .catch(() => {
          // Keep the last known count, including values bridged from a YouTube WebView.
        })
        .finally(() => {
          inFlightRef.current = false;
        });
    };
    refresh();
    const timer = setInterval(refresh, 30000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [active, reveal, stream]);

  if (count == null || count < 0) {
    return null;
  }

  return (
    <Animated.View style={[styles.viewerBadge, {opacity}]} pointerEvents="none">
      <Text style={styles.viewerBadgeIcon}>◇</Text>
      <Text style={styles.viewerBadgeText}>{count}人</Text>
    </Animated.View>
  );
});

const styles = StyleSheet.create({
  viewerBadge: {
    position: 'absolute',
    left: 10,
    bottom: 10,
    zIndex: 20,
    elevation: 20,
    minHeight: 28,
    paddingHorizontal: 8,
    borderRadius: 12,
    backgroundColor: 'rgba(0,0,0,0.62)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.12)',
    flexDirection: 'row',
    alignItems: 'center',
  },
  viewerBadgeIcon: {
    color: '#fff',
    fontSize: 12,
    marginRight: 5,
  },
  viewerBadgeText: {
    color: '#fff',
    fontSize: 12,
    fontWeight: '800',
  },
});
