import React, {useCallback, useEffect, useMemo, useState} from 'react';
import {ScrollView, StyleSheet, View} from 'react-native';
import {WebView, type WebViewMessageEvent} from 'react-native-webview';
import {adNetworkBlockerScript, isAdBlockedURL} from '../adblock';
import {mobileUserAgent} from '../playback';
import {sourceBridgeScript} from '../webInject';
import {parseStreamURL} from '../streamURL';
import type {PlatformId, Source} from '../types';
import {platformInfo} from '../platforms';
import {Pill} from '../components/Pill';
import {sharedStyles} from '../components/sharedStyles';

export function SourceBrowser({
  sources,
  blockWebAds,
  onAdd,
}: {
  sources: Source[];
  blockWebAds: boolean;
  onAdd: (platform: PlatformId, channel: string) => void;
}) {
  const [selected, setSelected] = useState(0);
  const source = sources[selected] ?? sources[0];

  useEffect(() => {
    if (selected >= sources.length) {
      setSelected(0);
    }
  }, [selected, sources.length]);

  const addParsed = useCallback(
    (rawURL: string) => {
      const parsed = parseStreamURL(rawURL);
      if (parsed) {
        onAdd(parsed.platform, parsed.channel);
        return true;
      }
      return false;
    },
    [onAdd],
  );

  const intercept = useCallback(
    (request: {url?: string; navigationType?: string}) => {
      const url = request.url ?? '';
      // iOS はフォロー/ランキングの WebView にも WebAdBlocker を入れる。RN では
      // navigation 単位の遮断をここで、DOM 単位の剥離を注入スクリプトで行う。
      if (blockWebAds && isAdBlockedURL(url)) {
        return false;
      }
      if (url && addParsed(url)) {
        return false;
      }
      return true;
    },
    [addParsed, blockWebAds],
  );

  // 6KB 超のスクリプト文字列をレンダー毎に連結しない。
  const injectedJavaScript = useMemo(
    () => (blockWebAds ? `${adNetworkBlockerScript}\n${sourceBridgeScript}` : sourceBridgeScript),
    [blockWebAds],
  );

  const handleMessage = useCallback(
    (event: WebViewMessageEvent) => {
      try {
        const payload = JSON.parse(event.nativeEvent.data);
        if (payload?.type === 'streamURL' && typeof payload.url === 'string') {
          addParsed(payload.url);
        }
      } catch {
        // Ignore bridge noise from websites.
      }
    },
    [addParsed],
  );

  if (!source) {
    return null;
  }

  return (
    <View style={sharedStyles.screen}>
      <View style={styles.browserFrame}>
        <WebView
          key={source.url}
          source={{uri: source.url}}
          userAgent={mobileUserAgent}
          javaScriptEnabled
          domStorageEnabled
          sharedCookiesEnabled
          thirdPartyCookiesEnabled
          setSupportMultipleWindows={false}
          injectedJavaScript={injectedJavaScript}
          onMessage={handleMessage}
          onShouldStartLoadWithRequest={intercept}
        />
      </View>
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        style={sharedStyles.sourceTabs}
        contentContainerStyle={styles.sourceTabsContent}>
        {sources.map((item, index) => (
          <Pill
            key={item.platform}
            active={selected === index}
            color={platformInfo(item.platform).color}
            label={item.label}
            onPress={() => setSelected(index)}
          />
        ))}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  sourceTabsContent: {
    paddingHorizontal: 10,
    paddingVertical: 8,
    alignItems: 'center',
  },
  browserFrame: {
    flex: 1,
    backgroundColor: '#000',
  },
});
