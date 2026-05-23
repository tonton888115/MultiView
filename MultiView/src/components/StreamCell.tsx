import React, { useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { WebView } from 'react-native-webview';
import { platformInfo } from '../config';
import { Settings, Stream } from '../types';
import { streamSource } from '../url';

interface Props {
  stream: Stream;
  settings: Settings;
  width: number;
  height: number;
  onFocus: (stream: Stream) => void;
  onRemove: (stream: Stream) => void;
}

function StreamCell({ stream, settings, width, height, onFocus, onRemove }: Props) {
  const webRef = useRef<WebView>(null);
  const [loading, setLoading] = useState(true);
  const [failed, setFailed] = useState(false);
  const info = platformInfo(stream.platform);
  const source = useMemo(() => streamSource(stream, settings), [stream, settings]);

  return (
    <View style={[styles.cell, { width, height }]}>
      {failed ? (
        <View style={styles.fallback}>
          <Text style={styles.fallbackText}>
            {info.label} / {stream.channel}
          </Text>
          <Text style={styles.fallbackSub}>読み込みに失敗しました</Text>
          <TouchableOpacity
            style={styles.reloadBtn}
            onPress={() => {
              setFailed(false);
              setLoading(true);
              webRef.current?.reload();
            }}>
            <Text style={styles.reloadText}>再読み込み</Text>
          </TouchableOpacity>
        </View>
      ) : (
        <WebView
          ref={webRef}
          source={source}
          style={styles.web}
          originWhitelist={['*']}
          javaScriptEnabled
          domStorageEnabled
          allowsInlineMediaPlayback
          mediaPlaybackRequiresUserAction={false}
          allowsFullscreenVideo
          sharedCookiesEnabled
          setSupportMultipleWindows={false}
          onLoadEnd={() => setLoading(false)}
          onError={() => {
            setLoading(false);
            setFailed(true);
          }}
        />
      )}

      {loading && !failed && (
        <View style={styles.loader} pointerEvents="none">
          <ActivityIndicator color="#fff" />
        </View>
      )}

      <View style={[styles.header, { borderTopColor: info.color }]} pointerEvents="box-none">
        <Text style={styles.label} numberOfLines={1}>
          <Text style={{ color: info.color }}>● </Text>
          {info.label} / {stream.channel}
        </Text>
        <TouchableOpacity hitSlop={6} onPress={() => onFocus(stream)} style={styles.iconBtn}>
          <Text style={styles.icon}>⛶</Text>
        </TouchableOpacity>
        <TouchableOpacity hitSlop={8} onPress={() => onRemove(stream)} style={styles.iconBtn}>
          <Text style={styles.closeText}>×</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  cell: {
    backgroundColor: '#000',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: '#222',
    overflow: 'hidden',
  },
  web: { flex: 1, backgroundColor: '#000' },
  loader: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    alignItems: 'center',
    justifyContent: 'center',
  },
  header: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    height: 26,
    flexDirection: 'row',
    alignItems: 'center',
    paddingLeft: 8,
    backgroundColor: 'rgba(0,0,0,0.55)',
    borderTopWidth: 2,
  },
  label: { flex: 1, color: '#eee', fontSize: 11, fontWeight: '600' },
  iconBtn: { width: 26, height: 26, alignItems: 'center', justifyContent: 'center' },
  icon: { color: '#fff', fontSize: 13 },
  closeText: { color: '#fff', fontSize: 18, lineHeight: 20 },
  fallback: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: 12 },
  fallbackText: { color: '#eee', fontSize: 13, fontWeight: '600', textAlign: 'center' },
  fallbackSub: { color: '#888', fontSize: 11, marginTop: 4 },
  reloadBtn: {
    marginTop: 12,
    paddingHorizontal: 16,
    paddingVertical: 8,
    backgroundColor: '#333',
    borderRadius: 6,
  },
  reloadText: { color: '#fff', fontSize: 12 },
});

export default React.memo(StreamCell);
