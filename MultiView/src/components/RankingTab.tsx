import React, { useState } from 'react';
import { StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { WebView } from 'react-native-webview';
import { parseStreamUrl, ParsedStream } from '../parseStreamUrl';

interface Props {
  onAddStream: (parsed: ParsedStream) => void;
}

interface Category {
  key: string;
  label: string;
  uri: string;
  host: string;
}

const CATEGORIES: Category[] = [
  { key: 'kick', label: 'Kick', uri: 'https://kick.com/browse', host: 'kick.com' },
  { key: 'twitch', label: 'Twitch', uri: 'https://ikioi-ranking.com/v/twitch', host: 'ikioi-ranking.com' },
  { key: 'youtube', label: 'YouTube', uri: 'https://ikioi-ranking.com/v/youtube', host: 'ikioi-ranking.com' },
  { key: 'niconama', label: 'ニコ生', uri: 'https://ikioi-ranking.com/v/niconama', host: 'ikioi-ranking.com' },
  { key: 'twitcasting', label: 'ツイキャス', uri: 'https://ikioi-ranking.com/v/twitcasting', host: 'ikioi-ranking.com' },
];

export default function RankingTab({ onAddStream }: Props) {
  const [cat, setCat] = useState<Category>(CATEGORIES[0]);

  function onShouldStart(req: { url: string; isTopFrame?: boolean }): boolean {
    if (req.isTopFrame === false) {
      return true;
    }
    const parsed = parseStreamUrl(req.url);
    if (parsed) {
      onAddStream(parsed);
      return false;
    }
    if (req.url.startsWith('about:') || req.url.startsWith('data:')) {
      return true;
    }
    // Allow navigation within the current source site; block other externals.
    const m = /^https?:\/\/([^/?#]+)/i.exec(req.url);
    const host = m ? m[1].replace(/^www\./, '') : '';
    return host === cat.host;
  }

  return (
    <View style={styles.root}>
      <View style={styles.tabs}>
        {CATEGORIES.map(c => {
          const on = c.key === cat.key;
          return (
            <TouchableOpacity
              key={c.key}
              style={[styles.tab, on && styles.tabActive]}
              onPress={() => setCat(c)}>
              <Text style={[styles.tabText, on && styles.tabTextActive]}>{c.label}</Text>
            </TouchableOpacity>
          );
        })}
      </View>
      <WebView
        key={cat.key}
        source={{ uri: cat.uri }}
        style={styles.web}
        originWhitelist={['*']}
        onShouldStartLoadWithRequest={onShouldStart}
        setSupportMultipleWindows={false}
        javaScriptEnabled
        domStorageEnabled
        sharedCookiesEnabled
      />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#111' },
  tabs: { flexDirection: 'row', backgroundColor: '#0c0c0c' },
  tab: { flex: 1, paddingVertical: 10, alignItems: 'center', borderBottomWidth: 2, borderBottomColor: 'transparent' },
  tabActive: { borderBottomColor: '#0a84ff' },
  tabText: { color: '#aaa', fontSize: 12, fontWeight: '600' },
  tabTextActive: { color: '#fff' },
  web: { flex: 1, backgroundColor: '#111' },
});
