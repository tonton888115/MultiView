import React, { useCallback, useEffect, useState } from 'react';
import {
  LayoutChangeEvent,
  StatusBar,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import AddStreamModal from './src/components/AddStreamModal';
import Grid from './src/components/Grid';
import SettingsModal from './src/components/SettingsModal';
import { DEFAULT_SETTINGS } from './src/config';
import {
  loadSettings,
  loadStreams,
  saveSettings,
  saveStreams,
} from './src/storage';
import { Platform, Settings, Stream } from './src/types';

function genId(): string {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function AppInner() {
  const [streams, setStreams] = useState<Stream[]>([]);
  const [settings, setSettings] = useState<Settings>(DEFAULT_SETTINGS);
  const [loaded, setLoaded] = useState(false);
  const [body, setBody] = useState({ width: 0, height: 0 });
  const [addVisible, setAddVisible] = useState(false);
  const [settingsVisible, setSettingsVisible] = useState(false);

  useEffect(() => {
    (async () => {
      const [s, cfg] = await Promise.all([loadStreams(), loadSettings()]);
      setStreams(s);
      setSettings(cfg);
      setLoaded(true);
    })();
  }, []);

  const addStream = useCallback((platform: Platform, channel: string) => {
    setStreams(prev => {
      const next = [...prev, { id: genId(), platform, channel }];
      saveStreams(next);
      return next;
    });
    setAddVisible(false);
  }, []);

  const removeStream = useCallback((id: string) => {
    setStreams(prev => {
      const next = prev.filter(s => s.id !== id);
      saveStreams(next);
      return next;
    });
  }, []);

  const onSaveSettings = useCallback((next: Settings) => {
    setSettings(next);
    saveSettings(next);
    setSettingsVisible(false);
  }, []);

  const onBodyLayout = (e: LayoutChangeEvent) => {
    const { width, height } = e.nativeEvent.layout;
    setBody({ width, height });
  };

  const needsSetup = loaded && !settings.baseUrl.trim();

  return (
    <SafeAreaView style={styles.root} edges={['top', 'left', 'right', 'bottom']}>
      <StatusBar barStyle="light-content" backgroundColor="#000" />

      <View style={styles.topBar}>
        <Text style={styles.brand}>MultiView</Text>
        <View style={styles.topActions}>
          <TouchableOpacity style={styles.iconBtn} onPress={() => setSettingsVisible(true)}>
            <Text style={styles.icon}>⚙</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.iconBtn, styles.addCircle]}
            onPress={() => setAddVisible(true)}>
            <Text style={styles.addPlus}>＋</Text>
          </TouchableOpacity>
        </View>
      </View>

      <View style={styles.body} onLayout={onBodyLayout}>
        {needsSetup ? (
          <View style={styles.center}>
            <Text style={styles.emptyTitle}>最初に設定が必要です</Text>
            <Text style={styles.emptySub}>
              配信を表示するには GitHub Pages の URL を設定してください。
            </Text>
            <TouchableOpacity style={styles.cta} onPress={() => setSettingsVisible(true)}>
              <Text style={styles.ctaText}>設定を開く</Text>
            </TouchableOpacity>
          </View>
        ) : streams.length === 0 ? (
          <View style={styles.center}>
            <Text style={styles.emptyTitle}>配信がありません</Text>
            <Text style={styles.emptySub}>＋ ボタンから配信を追加してください。</Text>
            <TouchableOpacity style={styles.cta} onPress={() => setAddVisible(true)}>
              <Text style={styles.ctaText}>配信を追加</Text>
            </TouchableOpacity>
          </View>
        ) : (
          body.width > 0 && (
            <Grid
              key={`${settings.baseUrl}|${settings.showChat ? 1 : 0}|${settings.proxyUrl}`}
              streams={streams}
              settings={settings}
              width={body.width}
              height={body.height}
              onRemove={removeStream}
            />
          )
        )}
      </View>

      <AddStreamModal
        visible={addVisible}
        currentCount={streams.length}
        onClose={() => setAddVisible(false)}
        onAdd={addStream}
      />
      <SettingsModal
        visible={settingsVisible}
        settings={settings}
        onClose={() => setSettingsVisible(false)}
        onSave={onSaveSettings}
      />
    </SafeAreaView>
  );
}

export default function App() {
  return (
    <SafeAreaProvider>
      <AppInner />
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#000' },
  topBar: {
    height: 48,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 14,
    backgroundColor: '#0c0c0c',
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#222',
  },
  brand: { color: '#fff', fontSize: 18, fontWeight: '800' },
  topActions: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  iconBtn: { width: 36, height: 36, alignItems: 'center', justifyContent: 'center' },
  icon: { color: '#ddd', fontSize: 20 },
  addCircle: { backgroundColor: '#0a84ff', borderRadius: 18 },
  addPlus: { color: '#fff', fontSize: 20, fontWeight: '700' },
  body: { flex: 1, backgroundColor: '#000' },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: 28 },
  emptyTitle: { color: '#fff', fontSize: 17, fontWeight: '700', marginBottom: 8 },
  emptySub: { color: '#999', fontSize: 13, textAlign: 'center', lineHeight: 19 },
  cta: {
    marginTop: 20,
    paddingHorizontal: 22,
    paddingVertical: 11,
    backgroundColor: '#0a84ff',
    borderRadius: 9,
  },
  ctaText: { color: '#fff', fontSize: 15, fontWeight: '600' },
});
