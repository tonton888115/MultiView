import React from 'react';
import { StyleSheet, Text, TouchableOpacity, View } from 'react-native';

export type TabKey = 'following' | 'ranking' | 'view' | 'settings';

const TABS: { key: TabKey; icon: string; label: string }[] = [
  { key: 'following', icon: '📡', label: 'フォロー' },
  { key: 'ranking', icon: '🏆', label: 'ランキング' },
  { key: 'view', icon: '▦', label: '視聴' },
  { key: 'settings', icon: '⚙', label: '設定' },
];

interface Props {
  active: TabKey;
  onChange: (tab: TabKey) => void;
}

export default function TabBar({ active, onChange }: Props) {
  return (
    <View style={styles.bar}>
      {TABS.map(t => {
        const on = t.key === active;
        return (
          <TouchableOpacity key={t.key} style={styles.item} onPress={() => onChange(t.key)}>
            <Text style={[styles.icon, on && styles.activeText]}>{t.icon}</Text>
            <Text style={[styles.label, on && styles.activeText]}>{t.label}</Text>
          </TouchableOpacity>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  bar: {
    flexDirection: 'row',
    backgroundColor: '#0c0c0c',
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: '#222',
  },
  item: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingVertical: 6 },
  icon: { fontSize: 18, color: '#888' },
  label: { fontSize: 10, color: '#888', marginTop: 2 },
  activeText: { color: '#0a84ff' },
});
