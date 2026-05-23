import React, { useMemo } from 'react';
import { StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { WebView } from 'react-native-webview';
import { platformInfo } from '../config';
import { Settings, Stream } from '../types';
import { chatSource, streamSource } from '../url';

interface Props {
  stream: Stream;
  settings: Settings;
  onClose: () => void;
}

export default function FocusedStream({ stream, settings, onClose }: Props) {
  const info = platformInfo(stream.platform);
  const video = useMemo(() => streamSource(stream, settings), [stream, settings]);
  const chat = useMemo(() => chatSource(stream), [stream]);

  return (
    <View style={styles.root}>
      <View style={styles.bar}>
        <TouchableOpacity onPress={onClose} hitSlop={8} style={styles.back}>
          <Text style={styles.backText}>← 戻る</Text>
        </TouchableOpacity>
        <Text style={styles.title} numberOfLines={1}>
          <Text style={{ color: info.color }}>● </Text>
          {info.label} / {stream.channel}
        </Text>
      </View>

      <View style={styles.video}>
        <WebView
          source={video}
          style={styles.web}
          originWhitelist={['*']}
          javaScriptEnabled
          domStorageEnabled
          allowsInlineMediaPlayback
          mediaPlaybackRequiresUserAction={false}
          allowsFullscreenVideo
          sharedCookiesEnabled
          setSupportMultipleWindows={false}
        />
      </View>

      {chat && (
        <View style={styles.chat}>
          <WebView
            source={chat}
            style={styles.web}
            originWhitelist={['*']}
            javaScriptEnabled
            domStorageEnabled
            sharedCookiesEnabled
            thirdPartyCookiesEnabled
            allowsInlineMediaPlayback
            mediaPlaybackRequiresUserAction={false}
            setSupportMultipleWindows={false}
          />
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#000' },
  bar: {
    height: 44,
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 12,
    backgroundColor: '#0c0c0c',
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#222',
  },
  back: { paddingRight: 12 },
  backText: { color: '#0a84ff', fontSize: 15, fontWeight: '600' },
  title: { flex: 1, color: '#fff', fontSize: 14, fontWeight: '700' },
  video: { flex: 3, backgroundColor: '#000' },
  chat: { flex: 2, backgroundColor: '#18181b' },
  web: { flex: 1, backgroundColor: '#000' },
});
