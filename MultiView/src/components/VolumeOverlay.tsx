import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {PanResponder, StyleSheet, Text, View} from 'react-native';
import type {StreamItem} from '../types';

// React.memo: 音量ドラッグ中の再レンダーをこのオーバーレイ内に閉じ込める。
// PanResponder は内部の useMemo/ref で管理しており memo 化の影響を受けない。
export const VolumeOverlay = React.memo(function VolumeOverlay({
  stream,
  volume,
  color,
  onVolume,
  onInteract,
  mode = 'cell',
}: {
  stream: StreamItem;
  volume: number;
  color: string;
  onVolume: (stream: StreamItem, volume: number) => void;
  onInteract?: () => void;
  mode?: 'cell' | 'focus';
}) {
  const [height, setHeight] = useState(0);
  // ドラッグ中はこのオーバーレイ内だけで描画し、親(Appルートのvolumes state)への
  // 反映は間引く。以前はmove毎に全画面再レンダー+AsyncStorage書込が走っていた。
  // 音量の音への追従は~100ms間隔で体感十分。
  const [dragVolume, setDragVolume] = useState<number | null>(null);
  const dragValueRef = useRef<number | null>(null);
  const lastCommitAtRef = useRef(0);
  const commitTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const commit = useCallback(
    (value: number) => {
      lastCommitAtRef.current = Date.now();
      onVolume(stream, value);
    },
    [onVolume, stream],
  );

  const throttledCommit = useCallback(
    (value: number) => {
      const elapsed = Date.now() - lastCommitAtRef.current;
      if (elapsed >= 100) {
        commit(value);
        return;
      }
      if (!commitTimerRef.current) {
        commitTimerRef.current = setTimeout(() => {
          commitTimerRef.current = null;
          if (dragValueRef.current !== null) {
            commit(dragValueRef.current);
          }
        }, 100 - elapsed);
      }
    },
    [commit],
  );

  useEffect(
    () => () => {
      if (commitTimerRef.current) {
        clearTimeout(commitTimerRef.current);
      }
    },
    [],
  );

  const updateFromY = useCallback(
    (locationY: number) => {
      if (height <= 0) {
        return;
      }
      onInteract?.();
      const next = 1 - Math.max(0, Math.min(height, locationY)) / height;
      dragValueRef.current = next;
      setDragVolume(next);
      throttledCommit(next);
    },
    [height, onInteract, throttledCommit],
  );
  const endDrag = useCallback(() => {
    if (commitTimerRef.current) {
      clearTimeout(commitTimerRef.current);
      commitTimerRef.current = null;
    }
    if (dragValueRef.current !== null) {
      commit(dragValueRef.current);
      dragValueRef.current = null;
    }
    setDragVolume(null);
  }, [commit]);
  const responder = useMemo(
    () =>
      PanResponder.create({
        onStartShouldSetPanResponder: () => true,
        onMoveShouldSetPanResponder: () => true,
        onPanResponderGrant: event => updateFromY(event.nativeEvent.locationY),
        onPanResponderMove: event => updateFromY(event.nativeEvent.locationY),
        onPanResponderRelease: endDrag,
        onPanResponderTerminate: endDrag,
      }),
    [endDrag, updateFromY],
  );

  const displayVolume = dragVolume ?? volume;
  return (
    <View
      style={[styles.volumeOverlay, mode === 'focus' ? styles.focusVolumeOverlay : styles.cellVolumeOverlay]}
      onLayout={event => setHeight(event.nativeEvent.layout.height)}
      {...responder.panHandlers}>
      <View style={styles.volumeTrack}>
        <View style={[styles.volumeLevel, {height: `${Math.round(displayVolume * 100)}%`, backgroundColor: color}]} />
        <View style={[styles.volumeThumb, {bottom: `${Math.round(displayVolume * 100)}%`}]} />
      </View>
      <Text style={styles.volumeIcon}>♪</Text>
    </View>
  );
});

const styles = StyleSheet.create({
  volumeOverlay: {
    position: 'absolute',
    width: 42,
    borderRadius: 18,
    backgroundColor: 'rgba(0,0,0,0.42)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.14)',
    alignItems: 'center',
    paddingTop: 12,
    paddingBottom: 10,
  },
  cellVolumeOverlay: {
    left: 10,
    top: 8,
    height: '62%',
  },
  focusVolumeOverlay: {
    right: 10,
    top: '15%',
    height: '70%',
  },
  volumeTrack: {
    flex: 1,
    width: 4,
    marginBottom: 10,
    borderRadius: 2,
    backgroundColor: 'rgba(255,255,255,0.28)',
    overflow: 'visible',
    justifyContent: 'flex-end',
  },
  volumeLevel: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    width: 4,
    borderRadius: 2,
  },
  volumeThumb: {
    position: 'absolute',
    left: -5.5,
    width: 15,
    height: 15,
    borderRadius: 7.5,
    backgroundColor: '#fff',
    transform: [{translateY: 7.5}],
  },
  volumeIcon: {
    color: '#fff',
    fontSize: 13,
    fontWeight: '800',
    lineHeight: 18,
  },
});
