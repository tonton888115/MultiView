import React from 'react';
import {
  Image,
  ImageSourcePropType,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';

export type TabKey = 'following' | 'ranking' | 'view' | 'settings';

const TABS: { key: TabKey; icon: ImageSourcePropType; label: string }[] = [
  {
    key: 'following',
    icon: require('../assets/tab-following.png'),
    label: 'フォロー',
  },
  {
    key: 'ranking',
    icon: require('../assets/tab-ranking.png'),
    label: 'ランキング',
  },
  { key: 'view', icon: require('../assets/tab-view.png'), label: '視聴' },
  {
    key: 'settings',
    icon: require('../assets/tab-settings.png'),
    label: '設定',
  },
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
          <TouchableOpacity
            key={t.key}
            style={styles.item}
            onPress={() => onChange(t.key)}
          >
            <Image
              source={t.icon}
              style={[styles.icon, on && styles.iconActive]}
              resizeMode="contain"
            />
            <Text style={[styles.label, on && styles.activeText]}>
              {t.label}
            </Text>
          </TouchableOpacity>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  bar: {
    flexDirection: 'row',
    backgroundColor: 'rgba(18,24,32,0.9)',
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: 'rgba(255,255,255,0.16)',
  },
  item: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: 6,
  },
  icon: { width: 22, height: 22, opacity: 0.56 },
  iconActive: { opacity: 1 },
  label: { fontSize: 10, color: '#888', marginTop: 2 },
  activeText: { color: '#0a84ff' },
});
