import React, { useState } from 'react';
import { StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { WebView } from 'react-native-webview';
import { parseStreamUrl, ParsedStream } from '../parseStreamUrl';

interface Props {
  onAddStream: (parsed: ParsedStream) => void;
}

const CATEGORIES: { key: string; label: string }[] = [
  { key: 'youtube', label: 'YouTube' },
  { key: 'twitch', label: 'Twitch' },
  { key: 'niconama', label: 'ニコ生' },
  { key: 'twitcasting', label: 'ツイキャス' },
];

export default function RankingTab({ onAddStream }: Props) {
  const [category, setCategory] = useState('youtube');

  function onShouldStart(req: { url: string; isTopFrame?: boolean }): boolean {
    // Only intercept top-frame navigations (let resources/subframes load).
    if (req.isTopFrame === false) {
      return true;
    }
    const url = req.url;
    if (/^https?:\/\/(www\.)?ikioi-ranking\.com/i.test(url)) {
      return true;
    }
    if (url.startsWith('about:') || url.startsWith('data:')) {
      return true;
    }
    const parsed = parseStreamUrl(url);
    if (parsed) {
      onAddStream(parsed);
    }
    // Don't navigate away from the ranking for external links.
    return false;
  }

  return (
    <View style={styles.root}>
      <View style={styles.tabs}>
        {CATEGORIES.map(c => {
          const active = c.key === category;
          return (
            <TouchableOpacity
              key={c.key}
              style={[styles.tab, active && styles.tabActive]}
              onPress={() => setCategory(c.key)}>
              <Text style={[styles.tabText, active && styles.tabTextActive]}>{c.label}</Text>
            </TouchableOpacity>
          );
        })}
      </View>
      <WebView
        key={category}
        source={{ uri: `https://ikioi-ranking.com/v/${category}` }}
        style={styles.web}
        originWhitelist={['*']}
        onShouldStartLoadWithRequest={onShouldStart}
        setSupportMultipleWindows={false}
        javaScriptEnabled
        domStorageEnabled
      />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#111' },
  tabs: { flexDirection: 'row', backgroundColor: '#0c0c0c' },
  tab: { flex: 1, paddingVertical: 10, alignItems: 'center', borderBottomWidth: 2, borderBottomColor: 'transparent' },
  tabActive: { borderBottomColor: '#0a84ff' },
  tabText: { color: '#aaa', fontSize: 13, fontWeight: '600' },
  tabTextActive: { color: '#fff' },
  web: { flex: 1, backgroundColor: '#111' },
});
