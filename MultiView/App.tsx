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
import FocusedStream from './src/components/FocusedStream';
import FollowingTab from './src/components/FollowingTab';
import Grid from './src/components/Grid';
import RankingTab from './src/components/RankingTab';
import SettingsTab from './src/components/SettingsTab';
import TabBar, { TabKey } from './src/components/TabBar';
import { DEFAULT_SETTINGS } from './src/config';
import { ParsedStream } from './src/parseStreamUrl';
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
  const [, setLoaded] = useState(false);
  const [tab, setTab] = useState<TabKey>('view');
  const [focused, setFocused] = useState<Stream | null>(null);
  const [body, setBody] = useState({ width: 0, height: 0 });
  const [addVisible, setAddVisible] = useState(false);

  useEffect(() => {
    (async () => {
      const [s, cfg] = await Promise.all([loadStreams(), loadSettings()]);
      setStreams(s);
      setSettings(cfg);
      setLoaded(true);
    })();
  }, []);

  const addStream = useCallback((platform: Platform, channel: string) => {
    const ch = channel.trim();
    if (!ch) {
      return;
    }
    setStreams(prev => {
      if (
        prev.some(
          s =>
            s.platform === platform &&
            s.channel.toLowerCase() === ch.toLowerCase(),
        )
      ) {
        return prev;
      }
      const next = [...prev, { id: genId(), platform, channel: ch }];
      saveStreams(next);
      return next;
    });
  }, []);

  const addParsed = useCallback(
    (p: ParsedStream) => {
      addStream(p.platform, p.channel);
      setTab('view');
    },
    [addStream],
  );

  const removeStream = useCallback((stream: Stream) => {
    setStreams(prev => {
      const next = prev.filter(s => s.id !== stream.id);
      saveStreams(next);
      return next;
    });
    setFocused(f => (f?.id === stream.id ? null : f));
  }, []);

  const onChangeSettings = useCallback((next: Settings) => {
    setSettings(next);
    saveSettings(next);
  }, []);

  const onBodyLayout = (e: LayoutChangeEvent) => {
    const { width, height } = e.nativeEvent.layout;
    setBody({ width, height });
  };

  return (
    <SafeAreaView
      style={styles.root}
      edges={['top', 'left', 'right', 'bottom']}
    >
      <StatusBar barStyle="light-content" backgroundColor="#000" />

      <View style={styles.content}>
        {/* View tab stays mounted so streams keep playing while other tabs are open */}
        <View
          style={[styles.page, tab !== 'view' && styles.hidden]}
          onLayout={onBodyLayout}
        >
          {focused ? (
            <FocusedStream
              stream={focused}
              settings={settings}
              onClose={() => setFocused(null)}
              onRemove={removeStream}
            />
          ) : streams.length === 1 ? (
            <FocusedStream
              stream={streams[0]}
              settings={settings}
              onClose={null}
              onRemove={removeStream}
            />
          ) : streams.length === 0 ? (
            <View style={styles.center}>
              <Text style={styles.emptyTitle}>配信がありません</Text>
              <Text style={styles.emptySub}>
                「ランキング」や「フォロー」タブから配信を選ぶか、＋で追加してください。
              </Text>
            </View>
          ) : (
            body.width > 0 && (
              <Grid
                streams={streams}
                settings={settings}
                width={body.width}
                height={body.height}
                onFocus={setFocused}
                onRemove={removeStream}
              />
            )
          )}

          {!focused && (
            <TouchableOpacity
              style={styles.fab}
              onPress={() => setAddVisible(true)}
            >
              <Text style={styles.fabText}>＋</Text>
            </TouchableOpacity>
          )}
        </View>

        {tab === 'ranking' && (
          <RankingTab
            platformOrder={settings.platformOrder}
            onAddStream={addParsed}
          />
        )}
        {tab === 'following' && (
          <FollowingTab
            platformOrder={settings.platformOrder}
            onAddStream={addParsed}
          />
        )}
        {tab === 'settings' && (
          <SettingsTab settings={settings} onChange={onChangeSettings} />
        )}
      </View>

      <TabBar active={tab} onChange={setTab} />

      <AddStreamModal
        visible={addVisible}
        currentCount={streams.length}
        platformOrder={settings.platformOrder}
        onClose={() => setAddVisible(false)}
        onAdd={(p, c) => {
          addStream(p, c);
          setAddVisible(false);
        }}
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
  root: { flex: 1, backgroundColor: '#05070a' },
  content: { flex: 1 },
  page: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: '#05070a',
  },
  hidden: { display: 'none' },
  center: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 28,
  },
  emptyTitle: {
    color: '#fff',
    fontSize: 17,
    fontWeight: '700',
    marginBottom: 8,
  },
  emptySub: {
    color: '#999',
    fontSize: 13,
    textAlign: 'center',
    lineHeight: 19,
  },
  fab: {
    position: 'absolute',
    right: 18,
    bottom: 18,
    width: 52,
    height: 52,
    borderRadius: 26,
    backgroundColor: 'rgba(10,132,255,0.82)',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: 'rgba(255,255,255,0.36)',
    alignItems: 'center',
    justifyContent: 'center',
    elevation: 4,
  },
  fabText: { color: '#fff', fontSize: 28, fontWeight: '700', marginTop: -2 },
});
