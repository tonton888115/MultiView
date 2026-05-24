import React, { useMemo } from 'react';
import { StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import { WebView } from 'react-native-webview';
import { platformInfo } from '../config';
import { Settings, Stream } from '../types';
import { chatSource, streamSource } from '../url';

interface Props {
  stream: Stream;
  settings: Settings;
  onClose: (() => void) | null;
  onRemove?: (stream: Stream) => void;
}

export default function FocusedStream({
  stream,
  settings,
  onClose,
  onRemove,
}: Props) {
  const info = platformInfo(stream.platform);
  const video = useMemo(
    () => streamSource(stream, settings),
    [stream, settings],
  );
  const chat = useMemo(() => chatSource(stream), [stream]);

  return (
    <View style={styles.root}>
      <View style={styles.bar}>
        {onClose && (
          <TouchableOpacity onPress={onClose} hitSlop={8} style={styles.back}>
            <Text style={styles.backText}>← 戻る</Text>
          </TouchableOpacity>
        )}
        <Text style={styles.title} numberOfLines={1}>
          <Text style={{ color: info.color }}>● </Text>
          {info.label} / {stream.channel}
        </Text>
        {onRemove && (
          <TouchableOpacity
            onPress={() => onRemove(stream)}
            hitSlop={8}
            style={styles.remove}
          >
            <Text style={styles.removeText}>×</Text>
          </TouchableOpacity>
        )}
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
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#000' },
  bar: {
    position: 'absolute',
    zIndex: 3,
    top: 10,
    left: 10,
    right: 10,
    height: 42,
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 12,
    backgroundColor: 'rgba(28,36,48,0.58)',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: 'rgba(255,255,255,0.24)',
    borderRadius: 18,
  },
  back: { paddingRight: 12 },
  backText: { color: '#0a84ff', fontSize: 15, fontWeight: '600' },
  title: { flex: 1, color: '#fff', fontSize: 14, fontWeight: '700' },
  remove: { paddingLeft: 12 },
  removeText: { color: '#fff', fontSize: 20, lineHeight: 22 },
  video: { flex: 1, backgroundColor: '#000' },
  chat: {
    position: 'absolute',
    left: 10,
    right: 10,
    bottom: 10,
    height: '42%',
    overflow: 'hidden',
    borderRadius: 18,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: 'rgba(255,255,255,0.18)',
    backgroundColor: 'rgba(18,20,26,0.72)',
  },
  web: { flex: 1, backgroundColor: '#000' },
});
