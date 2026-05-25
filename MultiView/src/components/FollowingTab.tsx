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

const SOURCES: { key: Platform; label: string; url: string }[] = [
  {
    key: 'twitch',
    label: 'Twitch',
    url: 'https://m.twitch.tv/directory/following',
  },
  {
    key: 'youtube',
    label: 'YouTube',
    url: 'https://m.youtube.com/feed/subscriptions',
  },
  { key: 'kick', label: 'Kick', url: 'https://kick.com/following' },
  { key: 'niconico', label: 'ニコ生', url: 'https://live.nicovideo.jp/follow' },
  { key: 'twitcasting', label: 'ツイキャス', url: 'https://twitcasting.tv/' },
];

export default function FollowingTab({ platformOrder, onAddStream }: Props) {
  const orderedSources = orderedPlatforms(platformOrder)
    .map(p => SOURCES.find(s => s.key === p.id))
    .filter((s): s is (typeof SOURCES)[number] => Boolean(s));
  const [active, setActive] = useState<Platform>('twitch');
  const current =
    orderedSources.find(s => s.key === active) ??
    orderedSources[0] ??
    SOURCES[0];

  function onShouldStart(req: { url: string; isTopFrame?: boolean }): boolean {
    if (req.isTopFrame === false) {
      return true;
    }
    // Tapping a followed stream adds it; everything else (login, browsing) navigates normally.
    const parsed = parseStreamUrl(req.url);
    if (parsed) {
      onAddStream(parsed);
      return false;
    }
    return true;
  }

  return (
    <View style={styles.root}>
      <View style={styles.tabs}>
        {orderedSources.map(s => {
          const on = s.key === current.key;
          return (
            <TouchableOpacity
              key={s.key}
              style={[styles.tab, on && styles.tabActive]}
              onPress={() => setActive(s.key)}
            >
              <Text style={[styles.tabText, on && styles.tabTextActive]}>
                {s.label}
              </Text>
            </TouchableOpacity>
          );
        })}
      </View>
      <Text style={styles.hint}>
        各サービスにログインすると、フォロー中の配信をタップで追加できます
      </Text>
      <WebView
        key={active}
        source={{ uri: current.url }}
        style={styles.web}
        originWhitelist={['*']}
        onShouldStartLoadWithRequest={onShouldStart}
        setSupportMultipleWindows={false}
        javaScriptEnabled
        domStorageEnabled
        sharedCookiesEnabled
        thirdPartyCookiesEnabled
      />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#111' },
  tabs: { flexDirection: 'row', backgroundColor: '#0c0c0c' },
  tab: {
    flex: 1,
    paddingVertical: 10,
    alignItems: 'center',
    borderBottomWidth: 2,
    borderBottomColor: 'transparent',
  },
  tabActive: { borderBottomColor: '#0a84ff' },
  tabText: { color: '#aaa', fontSize: 12, fontWeight: '600' },
  tabTextActive: { color: '#fff' },
  hint: {
    color: '#888',
    fontSize: 11,
    paddingHorizontal: 12,
    paddingVertical: 6,
    backgroundColor: '#161616',
  },
  web: { flex: 1, backgroundColor: '#111' },
});
