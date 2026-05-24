import React, { useState } from 'react';
import { StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { WebView } from 'react-native-webview';
import { orderedPlatforms } from '../config';
import { parseStreamUrl, ParsedStream } from '../parseStreamUrl';
import { Platform } from '../types';

interface Props {
  platformOrder: Platform[];
  onAddStream: (parsed: ParsedStream) => void;
}

interface Category {
  key: Platform;
  label: string;
  uri: string;
  host: string;
}

const CATEGORIES: Category[] = [
  {
    key: 'kick',
    label: 'Kick',
    uri: 'https://ikioi-ranking.com/v/kick',
    host: 'ikioi-ranking.com',
  },
  {
    key: 'twitch',
    label: 'Twitch',
    uri: 'https://ikioi-ranking.com/v/twitch',
    host: 'ikioi-ranking.com',
  },
  {
    key: 'youtube',
    label: 'YouTube',
    uri: 'https://ikioi-ranking.com/v/youtube',
    host: 'ikioi-ranking.com',
  },
  {
    key: 'niconico',
    label: 'ニコ生',
    uri: 'https://ikioi-ranking.com/v/niconama',
    host: 'ikioi-ranking.com',
  },
  {
    key: 'twitcasting',
    label: 'ツイキャス',
    uri: 'https://ikioi-ranking.com/v/twitcasting',
    host: 'ikioi-ranking.com',
  },
];

export default function RankingTab({ platformOrder, onAddStream }: Props) {
  const orderedCategories = orderedPlatforms(platformOrder)
    .map(p => CATEGORIES.find(c => c.key === p.id))
    .filter((c): c is Category => Boolean(c));
  const [cat, setCat] = useState<Category>(
    orderedCategories[0] ?? CATEGORIES[0],
  );
  const currentCat =
    orderedCategories.find(c => c.key === cat.key) ??
    orderedCategories[0] ??
    CATEGORIES[0];

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
    return host === currentCat.host;
  }

  return (
    <View style={styles.root}>
      <View style={styles.tabs}>
        {orderedCategories.map(c => {
          const on = c.key === currentCat.key;
          return (
            <TouchableOpacity
              key={c.key}
              style={[styles.tab, on && styles.tabActive]}
              onPress={() => setCat(c)}
            >
              <Text style={[styles.tabText, on && styles.tabTextActive]}>
                {c.label}
              </Text>
            </TouchableOpacity>
          );
        })}
      </View>
      <WebView
        key={currentCat.key}
        source={{ uri: currentCat.uri }}
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
  root: { flex: 1, backgroundColor: '#05070a' },
  tabs: {
    flexDirection: 'row',
    margin: 10,
    padding: 3,
    borderRadius: 18,
    backgroundColor: 'rgba(255,255,255,0.08)',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: 'rgba(255,255,255,0.16)',
  },
  tab: {
    flex: 1,
    paddingVertical: 10,
    alignItems: 'center',
    borderBottomWidth: 2,
    borderBottomColor: 'transparent',
  },
  tabActive: {
    borderBottomColor: '#0a84ff',
    backgroundColor: 'rgba(10,132,255,0.18)',
    borderRadius: 14,
  },
  tabText: { color: '#aaa', fontSize: 12, fontWeight: '600' },
  tabTextActive: { color: '#fff' },
  web: { flex: 1, backgroundColor: '#111' },
});
