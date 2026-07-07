import React from 'react';
import {StyleSheet, Text, View} from 'react-native';
import type {PlaybackSource} from '../types';

export const PlayerBadge = React.memo(function PlayerBadge({source, status, warning}: {source: PlaybackSource; status: string; warning?: boolean}) {
  return (
    <View style={[styles.playerBadge, warning && styles.playerBadgeWarning]}>
      <Text style={styles.playerBadgeText} numberOfLines={1}>
        {source.label} / {status}
      </Text>
    </View>
  );
});

const styles = StyleSheet.create({
  playerBadge: {
    position: 'absolute',
    left: 8,
    bottom: 8,
    maxWidth: '88%',
    minHeight: 24,
    paddingHorizontal: 8,
    borderRadius: 7,
    backgroundColor: 'rgba(5, 7, 10, 0.76)',
    justifyContent: 'center',
  },
  playerBadgeWarning: {
    backgroundColor: 'rgba(58, 23, 32, 0.82)',
  },
  playerBadgeText: {
    color: '#dce6f3',
    fontSize: 11,
    fontWeight: '700',
  },
});
