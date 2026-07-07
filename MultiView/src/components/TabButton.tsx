import React from 'react';
import {StyleSheet, Text, TouchableOpacity, View} from 'react-native';

// iOS MainTabController のタブ(SF Symbols + tint)に寄せる。Android では SF Symbols が
// 使えないため、既定フォントで確実にモノクロ描画され color でティントできる記号を使う
// (絵文字化する字は不可 — 設定の歯車は VS15 でテキスト表示を強制)。
export function TabButton({active, icon, label, onPress}: {active: boolean; icon: string; label: string; onPress: () => void}) {
  return (
    <TouchableOpacity
      style={styles.tabButton}
      onPress={onPress}
      accessibilityRole="tab"
      accessibilityState={{selected: active}}>
      <View style={[styles.tabIndicator, active && styles.tabIndicatorActive]} />
      <Text style={[styles.tabIcon, active && styles.tabIconActive]}>{icon}</Text>
      <Text style={[styles.tabText, active && styles.tabTextActive]}>{label}</Text>
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
  tabButton: {
    flex: 1,
    minHeight: 51,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 7,
  },
  tabIndicator: {
    width: 28,
    height: 3,
    marginBottom: 3,
    borderRadius: 1.5,
    backgroundColor: 'transparent',
  },
  tabIndicatorActive: {
    backgroundColor: '#67a8ff',
  },
  tabIcon: {
    color: '#8a93a6',
    fontSize: 18,
    lineHeight: 21,
  },
  tabIconActive: {
    color: '#67a8ff',
  },
  tabText: {
    color: '#8a93a6',
    fontSize: 11,
    fontWeight: '600',
    marginTop: 1,
  },
  tabTextActive: {
    color: '#67a8ff',
    fontWeight: '700',
  },
});
