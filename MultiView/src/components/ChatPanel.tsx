import React from 'react';
import { StyleSheet, Modal, Text, TouchableOpacity, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { WebView } from 'react-native-webview';
import { platformInfo } from '../config';
import { Stream } from '../types';

interface Props {
  stream: Stream | null;
  url: string | null;
  onClose: () => void;
}

export default function ChatPanel({ stream, url, onClose }: Props) {
  const visible = !!stream && !!url;
  const info = stream ? platformInfo(stream.platform) : null;

  return (
    <Modal visible={visible} animationType="slide" onRequestClose={onClose}>
      <SafeAreaView style={styles.root} edges={['top', 'left', 'right', 'bottom']}>
        <View style={styles.header}>
          <Text style={styles.title} numberOfLines={1}>
            {info ? `${info.label} / ${stream!.channel}` : ''} のチャット
          </Text>
          <TouchableOpacity onPress={onClose} style={styles.close} hitSlop={8}>
            <Text style={styles.closeText}>閉じる</Text>
          </TouchableOpacity>
        </View>
        {visible && (
          <WebView
            source={{ uri: url! }}
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
        )}
      </SafeAreaView>
    </Modal>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#18181b' },
  header: {
    height: 48,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 14,
    backgroundColor: '#0c0c0c',
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#222',
  },
  title: { flex: 1, color: '#fff', fontSize: 15, fontWeight: '700' },
  close: { paddingHorizontal: 8, paddingVertical: 6 },
  closeText: { color: '#0a84ff', fontSize: 15, fontWeight: '600' },
  web: { flex: 1, backgroundColor: '#18181b' },
});
