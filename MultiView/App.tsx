import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {
  ActivityIndicator,
  Alert,
  Animated,
  Modal,
  SafeAreaView,
  ScrollView,
  PanResponder,
  Pressable,
  StatusBar,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  TouchableOpacity,
  View,
  Linking,
} from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';
import {WebView, type WebViewMessageEvent} from 'react-native-webview';
import {DanmakuOverlay} from './src/DanmakuOverlay';
import {NativeHlsPlayer} from './src/NativeHlsPlayer';
import {
  AUTH_STORAGE_KEY,
  authStatus,
  completeOAuthRedirect,
  createOAuthStart,
  defaultAuthState,
  openURL,
  pollYouTubeDeviceToken,
  postStreamComment,
  requestYouTubeDeviceCode,
  sanitizeAuthState,
  serviceLabel,
  signOut,
  updateAuthConfig,
  type AuthState,
  type OAuthService,
  type PendingOAuth,
} from './src/auth';
import {compactHandoffCode, decodeHandoff, handoffURL} from './src/handoff';
import {
  chatURL,
  desktopUserAgent,
  effectiveQuality,
  makeStream,
  mobileUserAgent,
  resolvePlaybackSource,
  resolveLiveYouTubeVideoID,
  webStreamURL,
  youtubeClients,
  youtubeIframeHTML,
  youtubeVideoId,
} from './src/playback';
import type {AppSettings, PlatformId, PlaybackSource, Source, StreamItem, TabId} from './src/types';
import {adNetworkBlockerScript, isAdBlockedURL, platformAdBlockExtras} from './src/adblock';
import {setRaidHandler} from './src/raidFollow';
import {niconicoOriginURL, niconicoQuality, niconicoSessionScript} from './src/niconico';
import {pushNiconicoComment} from './src/niconicoComments';
import {startPlaybackService, stopPlaybackService} from './src/playbackService';

const STREAMS_KEY = 'multiview.android.streams.v2';
const LEGACY_STREAMS_KEY = 'multiview.android.streams.v1';
const SETTINGS_KEY = 'multiview.android.settings.v2';
const LEGACY_SETTINGS_KEY = 'multiview.android.settings.v1';
const VOLUMES_KEY = 'multiview.android.volumes.v1';
const chromeAutoHideDelayMs = 2400;

const platformIds: PlatformId[] = ['kick', 'twitch', 'youtube', 'niconico', 'twitcasting'];
const youtubeViewerKeys = ['concurrentViewers', 'concurrent_viewers'];
const niconicoCurrentViewerKeys = ['currentViewers', 'currentViewerCount', 'current_viewers', 'current_viewer_count', 'viewerCount', 'viewersCount'];
const settingsSchemaVersion = 3;
const youtubeViewerFetchTimeoutMs = 30000;
const youtubePlayerViewerFetchTimeoutMs = 8000;

const defaultSettings: AppSettings = {
  settingsVersion: settingsSchemaVersion,
  showChat: true,
  showDanmaku: true,
  showEmotes: true,
  showViewerCount: true,
  playAudio: true,
  autoFollowRaids: false,
  blockWebAds: true,
  youtubePreferIframe: false,
  youtubeStableBuffer: true,
  layoutMode: 'stacked',
  wifiQuality: 'high',
  mobileQuality: 'economy',
  danmakuFontSize: 20,
  danmakuSpeed: 0.13,
  danmakuOpacity: 0.9,
  danmakuMaxLines: 0,
  danmakuMaxLength: 0,
  niconicoLowLatency: false,
  showGiftEffects: true,
  giftSoundEnabled: true,
  niconicoShowGift: true,
  niconicoShowNicoad: true,
  niconicoShowNotification: true,
  autoEconomyOnManyStreams: true,
  platformOrder: platformIds,
};

const platforms: Array<{id: PlatformId; label: string; hint: string; color: string}> = [
  {id: 'kick', label: 'Kick', hint: 'チャンネル名', color: '#53fc18'},
  {id: 'twitch', label: 'Twitch', hint: 'チャンネル名', color: '#9146ff'},
  {id: 'youtube', label: 'YouTube', hint: '動画ID / @handle / URL', color: '#ff3030'},
  {id: 'niconico', label: 'ニコ生', hint: '番組ID(lv...) / URL', color: '#ff8a20'},
  {id: 'twitcasting', label: 'ツイキャス', hint: 'ユーザーID', color: '#00a6ef'},
];

const rankingSources: Source[] = [
  {platform: 'kick', label: 'Kick', url: 'https://ikioi-ranking.com/v/kick'},
  {platform: 'twitch', label: 'Twitch', url: 'https://ikioi-ranking.com/v/twitch'},
  {platform: 'youtube', label: 'YouTube', url: 'https://ikioi-ranking.com/v/youtube'},
  {platform: 'niconico', label: 'ニコ生', url: 'https://ikioi-ranking.com/category/nico_user'},
  {platform: 'twitcasting', label: 'ツイキャス', url: 'https://ikioi-ranking.com/v/twitcasting'},
];

const followingSources: Source[] = [
  {platform: 'twitch', label: 'Twitch', url: 'https://m.twitch.tv/directory/following'},
  {platform: 'youtube', label: 'YouTube', url: 'https://m.youtube.com/feed/subscriptions'},
  {platform: 'kick', label: 'Kick', url: 'https://kick.com/following'},
  {platform: 'niconico', label: 'ニコ生', url: 'https://live.nicovideo.jp/follow'},
  {platform: 'twitcasting', label: 'ツイキャス', url: 'https://twitcasting.tv/'},
];

const kickNonStreamPaths = new Set([
  'browse',
  'categories',
  'category',
  'following',
  'search',
  'clips',
  'about',
  'help',
  'dashboard',
  'messages',
  'settings',
  'subscriptions',
  'login',
  'signup',
  'auth',
  'oauth',
]);

const twitchNonStreamPaths = new Set([
  'directory',
  'videos',
  'login',
  'signup',
  'p',
  'settings',
  'subscriptions',
  'wallet',
  'drops',
  'u',
  'downloads',
  'jobs',
  'privacy',
  'terms',
  'turbo',
  'store',
]);

function platformInfo(id: PlatformId) {
  return platforms.find(platform => platform.id === id) ?? platforms[0];
}

function orderedPlatforms(order: PlatformId[]) {
  const merged = [...order, ...platformIds];
  return merged.reduce<PlatformId[]>((result, platform) => {
    if (platformIds.includes(platform) && !result.includes(platform)) {
      result.push(platform);
    }
    return result;
  }, []);
}

function orderedSources(sources: Source[], settings: AppSettings) {
  const order = orderedPlatforms(settings.platformOrder);
  return order.flatMap(platform => sources.filter(source => source.platform === platform));
}

function stripWww(host: string): string {
  return host.replace(/^www\./, '').toLowerCase();
}

function parseStreamURL(raw: string): {platform: PlatformId; channel: string} | null {
  try {
    const url = new URL(raw);
    const host = stripWww(url.hostname);
    const parts = url.pathname.split('/').filter(Boolean).map(decodeURIComponent);

    if (host === 'live-info.soraweb.net') {
      const linked = url.searchParams.get('link');
      if (linked) {
        const parsed = parseStreamURL(linked);
        if (parsed) {
          return parsed;
        }
      }
      const site = url.searchParams.get('site');
      const liveNo = url.searchParams.get('liveNo');
      if (site === 'nico' && liveNo) {
        return {platform: 'niconico', channel: liveNo.startsWith('lv') ? liveNo : `lv${liveNo}`};
      }
    }

    if (host === 'kick.com' && parts[0] && !kickNonStreamPaths.has(parts[0])) {
      return {platform: 'kick', channel: parts[0]};
    }
    if ((host === 'twitch.tv' || host === 'm.twitch.tv') && parts[0] && !twitchNonStreamPaths.has(parts[0])) {
      return {platform: 'twitch', channel: parts[0]};
    }
    if (host.includes('youtube.com')) {
      const videoId = url.searchParams.get('v');
      if (videoId) {
        return {platform: 'youtube', channel: videoId};
      }
      if (['live', 'embed', 'shorts'].includes(parts[0]) && parts[1]) {
        return {platform: 'youtube', channel: parts[1]};
      }
      if (parts[0]?.startsWith('@') || ['channel', 'c', 'user'].includes(parts[0])) {
        return {platform: 'youtube', channel: parts.join('/')};
      }
    }
    if (host === 'youtu.be' && parts[0]) {
      return {platform: 'youtube', channel: parts[0]};
    }
    if (host.includes('live.nicovideo.jp') && parts[0] === 'watch' && parts[1]) {
      return {platform: 'niconico', channel: parts.slice(1).join('/')};
    }
    if (host === 'twitcasting.tv' && parts[0] && parts[0] !== 'search') {
      return {platform: 'twitcasting', channel: parts[0]};
    }
  } catch {
    return null;
  }
  return null;
}

function sanitizeSettings(raw: unknown): AppSettings {
  const source = typeof raw === 'object' && raw ? (raw as Partial<AppSettings>) : {};
  const sourceVersion = typeof source.settingsVersion === 'number' ? source.settingsVersion : 0;
  const migrateViewerCountDefault = source.showViewerCount === false && sourceVersion < settingsSchemaVersion;
  return {
    ...defaultSettings,
    ...source,
    settingsVersion: settingsSchemaVersion,
    showViewerCount: migrateViewerCountDefault
      ? true
      : typeof source.showViewerCount === 'boolean'
        ? source.showViewerCount
        : defaultSettings.showViewerCount,
    platformOrder: orderedPlatforms(Array.isArray(source.platformOrder) ? source.platformOrder : platformIds),
    layoutMode: source.layoutMode === 'grid' ? 'grid' : source.layoutMode === 'stacked' ? 'stacked' : defaultSettings.layoutMode,
    wifiQuality: source.wifiQuality === 'economy' ? 'economy' : 'high',
    mobileQuality: source.mobileQuality === 'high' ? 'high' : 'economy',
    danmakuFontSize: clampNumber(source.danmakuFontSize, 12, 40, defaultSettings.danmakuFontSize),
    danmakuSpeed: clampNumber(source.danmakuSpeed, 0.026, 0.39, defaultSettings.danmakuSpeed),
    danmakuOpacity: clampNumber(source.danmakuOpacity, 0.3, 1, defaultSettings.danmakuOpacity),
    danmakuMaxLines: Math.round(clampNumber(source.danmakuMaxLines, 0, 20, defaultSettings.danmakuMaxLines)),
    danmakuMaxLength: Math.round(clampNumber(source.danmakuMaxLength, 0, 500, defaultSettings.danmakuMaxLength)),
  };
}

function clampNumber(value: unknown, min: number, max: number, fallback: number): number {
  const number = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(number)) {
    return fallback;
  }
  return Math.min(max, Math.max(min, number));
}

function useAutoHidingChrome(resetKey: unknown) {
  const [visible, setVisible] = useState(true);
  const hideTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const clearHideTimer = useCallback(() => {
    if (hideTimerRef.current) {
      clearTimeout(hideTimerRef.current);
      hideTimerRef.current = null;
    }
  }, []);

  const show = useCallback(() => {
    clearHideTimer();
    setVisible(true);
    hideTimerRef.current = setTimeout(() => {
      hideTimerRef.current = null;
      setVisible(false);
    }, chromeAutoHideDelayMs);
  }, [clearHideTimer]);

  useEffect(() => {
    show();
    return clearHideTimer;
  }, [clearHideTimer, resetKey, show]);

  return {chromeVisible: visible, showChrome: show};
}

export default function App() {
  const [hydrated, setHydrated] = useState(false);
  const [activeTab, setActiveTab] = useState<TabId>('viewing');
  const [streams, setStreams] = useState<StreamItem[]>([]);
  const [settings, setSettings] = useState<AppSettings>(defaultSettings);
  const [volumes, setVolumes] = useState<Record<string, number>>({});
  const [auth, setAuth] = useState<AuthState>(defaultAuthState);
  const [pendingOAuth, setPendingOAuth] = useState<PendingOAuth | null>(null);
  const [niconicoLoginOpen, setNiconicoLoginOpen] = useState(false);
  const authRef = useRef(auth);
  const pendingOAuthRef = useRef(pendingOAuth);
  const pendingHandoffURLRef = useRef<string | null>(null);
  authRef.current = auth;
  pendingOAuthRef.current = pendingOAuth;

  const applyHandoffURL = useCallback((url: string) => {
    const decoded = decodeHandoff(url);
    const nextStreams = decoded.streams.map(stream => makeStream(stream.platform, stream.channel));
    setStreams(nextStreams);
    setSettings(current => ({...current, ...decoded.settings}));
    setActiveTab('viewing');
  }, []);

  useEffect(() => {
    let mounted = true;
    Promise.all([
      AsyncStorage.getItem(STREAMS_KEY).then(value => value ?? AsyncStorage.getItem(LEGACY_STREAMS_KEY)),
      AsyncStorage.getItem(SETTINGS_KEY).then(value => value ?? AsyncStorage.getItem(LEGACY_SETTINGS_KEY)),
      AsyncStorage.getItem(VOLUMES_KEY),
      AsyncStorage.getItem(AUTH_STORAGE_KEY),
    ])
      .then(([savedStreams, savedSettings, savedVolumes, savedAuth]) => {
        if (!mounted) {
          return;
        }
        if (savedStreams) {
          const parsed = JSON.parse(savedStreams);
          if (Array.isArray(parsed)) {
            setStreams(
              parsed
                .filter(stream => stream.platform && stream.channel)
                .map(stream => makeStream(stream.platform as PlatformId, String(stream.channel))),
            );
          }
        }
        if (savedSettings) {
          setSettings(sanitizeSettings(JSON.parse(savedSettings)));
        }
        if (savedVolumes) {
          setVolumes(JSON.parse(savedVolumes));
        }
        if (savedAuth) {
          setAuth(sanitizeAuthState(JSON.parse(savedAuth)));
        }
      })
      .catch(() => {
        Alert.alert('読み込み失敗', '保存データを読み込めませんでした。');
      })
      .finally(() => mounted && setHydrated(true));
    return () => {
      mounted = false;
    };
  }, []);

  useEffect(() => {
    if (hydrated) {
      AsyncStorage.setItem(STREAMS_KEY, JSON.stringify(streams)).catch(() => undefined);
    }
  }, [hydrated, streams]);

  useEffect(() => {
    if (hydrated) {
      AsyncStorage.setItem(SETTINGS_KEY, JSON.stringify(settings)).catch(() => undefined);
    }
  }, [hydrated, settings]);

  useEffect(() => {
    if (hydrated) {
      AsyncStorage.setItem(VOLUMES_KEY, JSON.stringify(volumes)).catch(() => undefined);
    }
  }, [hydrated, volumes]);

  useEffect(() => {
    if (hydrated) {
      AsyncStorage.setItem(AUTH_STORAGE_KEY, JSON.stringify(auth)).catch(() => undefined);
    }
  }, [auth, hydrated]);

  useEffect(() => {
    if (!hydrated || !pendingHandoffURLRef.current) {
      return;
    }
    const url = pendingHandoffURLRef.current;
    pendingHandoffURLRef.current = null;
    try {
      applyHandoffURL(url);
    } catch {
      Alert.alert('読み込み失敗', '引き継ぎURLを読み込めませんでした。');
    }
  }, [applyHandoffURL, hydrated]);

  useEffect(() => {
    const handleURL = ({url}: {url: string}) => {
      if (url.startsWith('multiview://handoff')) {
        if (!hydrated) {
          pendingHandoffURLRef.current = url;
          return;
        }
        try {
          applyHandoffURL(url);
        } catch {
          Alert.alert('読み込み失敗', '引き継ぎURLを読み込めませんでした。');
        }
        return;
      }
      const pending = pendingOAuthRef.current;
      if (!pending || !url.startsWith('multiview://')) {
        return;
      }
      completeOAuthRedirect(authRef.current, pending, url)
        .then(next => {
          setAuth(next);
          setPendingOAuth(null);
          Alert.alert('ログイン完了', `${serviceLabel(pending.service)}にログインしました。`);
        })
        .catch(error => {
          setPendingOAuth(null);
          Alert.alert('ログイン失敗', error instanceof Error ? error.message : String(error));
        });
    };
    const sub = Linking.addEventListener('url', handleURL);
    Linking.getInitialURL().then(url => {
      if (url) {
        handleURL({url});
      }
    }).catch(() => undefined);
    return () => sub.remove();
  }, [applyHandoffURL, hydrated]);

  const updateAuth = useCallback((next: AuthState) => {
    setAuth(sanitizeAuthState(next));
  }, []);

  const startOAuthLogin = useCallback(async (service: OAuthService) => {
    try {
      if (service === 'youtube') {
        const device = await requestYouTubeDeviceCode(authRef.current);
        Alert.alert(
          'YouTubeログイン',
          `外部ブラウザで ${device.verificationUrl} を開き、コード ${device.userCode} を入力してください。完了まで自動で待機します。`,
        );
        openURL(device.verificationUrl).catch(() => undefined);
        const poll = async () => {
          if (Date.now() > device.expiresAt) {
            Alert.alert('YouTubeログイン失敗', '認証コードの期限が切れました。もう一度ログインしてください。');
            return;
          }
          try {
            const next = await pollYouTubeDeviceToken(authRef.current, device);
            if (next) {
              setAuth(next);
              Alert.alert('ログイン完了', 'YouTubeにログインしました。');
              return;
            }
            setTimeout(poll, device.intervalSeconds * 1000);
          } catch (error) {
            Alert.alert('YouTubeログイン失敗', error instanceof Error ? error.message : String(error));
          }
        };
        setTimeout(poll, device.intervalSeconds * 1000);
        return;
      }
      const start = await createOAuthStart(authRef.current, service);
      setPendingOAuth(start.pending);
      await openURL(start.url);
    } catch (error) {
      Alert.alert('ログイン開始失敗', error instanceof Error ? error.message : String(error));
    }
  }, []);

  const addStream = useCallback((platform: PlatformId, rawChannel: string) => {
    const fromURL = parseStreamURL(rawChannel);
    const next = fromURL ? makeStream(fromURL.platform, fromURL.channel) : makeStream(platform, rawChannel);
    if (!next.channel) {
      return;
    }
    setStreams(current => {
      if (current.some(stream => stream.id === next.id)) {
        return current;
      }
      return [...current, next];
    });
    setActiveTab('viewing');
  }, []);

  // レイド/ホスト自動追従。chat.ts が検出した宛先を module-level ハンドラ経由で受け取り、
  // autoFollowRaids が ON の時だけ streams へ追加して視聴タブへ切り替える(iOS RaidAutoFollow 相当)。
  useEffect(() => {
    setRaidHandler((platform, channel) => {
      if (settings.autoFollowRaids) {
        addStream(platform, channel);
      }
    });
    return () => setRaidHandler(null);
  }, [addStream, settings.autoFollowRaids]);

  // 背景音声: 配信が1本以上 & 音声ON の間だけ前面サービスを起動しておく。前面にいるうちに
  // start するので、その後バックグラウンドに入ってもプロセスが生き、音声再生が継続する。
  useEffect(() => {
    if (!hydrated) {
      return;
    }
    if (streams.length > 0 && settings.playAudio) {
      startPlaybackService();
    } else {
      stopPlaybackService();
    }
  }, [hydrated, streams.length, settings.playAudio]);

  const removeStream = useCallback((id: string) => {
    setStreams(current => current.filter(stream => stream.id !== id));
    setVolumes(current => {
      const next = {...current};
      delete next[id];
      return next;
    });
  }, []);

  const moveStreamTo = useCallback((index: number, target: number) => {
    setStreams(current => {
      if (index < 0 || index >= current.length) {
        return current;
      }
      const nextTarget = Math.max(0, Math.min(target, current.length - 1));
      if (nextTarget === index) {
        return current;
      }
      const next = current.slice();
      const [item] = next.splice(index, 1);
      next.splice(nextTarget, 0, item);
      return next;
    });
  }, []);

  const updateSettings = useCallback((patch: Partial<AppSettings>) => {
    setSettings(current => sanitizeSettings({...current, ...patch}));
  }, []);

  const setStreamVolume = useCallback((stream: StreamItem, volume: number) => {
    setVolumes(current => ({...current, [stream.id]: Math.max(0, Math.min(1, volume))}));
  }, []);

  return (
    <SafeAreaView style={styles.app}>
      <StatusBar barStyle="light-content" backgroundColor="#05070a" translucent={false} />
      <View style={styles.content}>
        {activeTab === 'following' && (
          <SourceBrowser sources={orderedSources(followingSources, settings)} onAdd={addStream} />
        )}
        {activeTab === 'ranking' && (
          <SourceBrowser sources={orderedSources(rankingSources, settings)} onAdd={addStream} />
        )}
        {activeTab === 'viewing' && (
          <ViewingScreen
            streams={streams}
            settings={settings}
            volumes={volumes}
            onAdd={addStream}
            onRemove={removeStream}
            onMove={moveStreamTo}
            onVolume={setStreamVolume}
            onSettings={updateSettings}
            auth={auth}
            onAuth={updateAuth}
          />
        )}
        {activeTab === 'settings' && (
          <SettingsScreen
            streams={streams}
            settings={settings}
            onSettings={updateSettings}
            onImport={(nextStreams, nextSettings) => {
              setStreams(nextStreams);
              setSettings(sanitizeSettings({...settings, ...nextSettings}));
              setActiveTab('viewing');
            }}
            onMovePlatform={(index, delta) => {
              const order = orderedPlatforms(settings.platformOrder);
              const target = index + delta;
              if (target < 0 || target >= order.length) {
                return;
              }
              const next = order.slice();
              const [item] = next.splice(index, 1);
              next.splice(target, 0, item);
              updateSettings({platformOrder: next});
            }}
            onClear={() => setStreams([])}
            auth={auth}
            onAuth={updateAuth}
            onLogin={startOAuthLogin}
            onNiconicoLogin={() => setNiconicoLoginOpen(true)}
          />
        )}
      </View>
      <NiconicoLoginModal visible={niconicoLoginOpen} onClose={() => setNiconicoLoginOpen(false)} />

      <View style={styles.tabBar}>
        <TabButton active={activeTab === 'following'} label="フォロー" onPress={() => setActiveTab('following')} />
        <TabButton active={activeTab === 'ranking'} label="ランキング" onPress={() => setActiveTab('ranking')} />
        <TabButton active={activeTab === 'viewing'} label="視聴" onPress={() => setActiveTab('viewing')} />
        <TabButton active={activeTab === 'settings'} label="設定" onPress={() => setActiveTab('settings')} />
      </View>
    </SafeAreaView>
  );
}

function TabButton({active, label, onPress}: {active: boolean; label: string; onPress: () => void}) {
  return (
    <TouchableOpacity style={[styles.tabButton, active && styles.tabButtonActive]} onPress={onPress}>
      <Text style={[styles.tabText, active && styles.tabTextActive]}>{label}</Text>
    </TouchableOpacity>
  );
}

function Pill({active, color, label, onPress}: {active: boolean; color?: string; label: string; onPress: () => void}) {
  return (
    <TouchableOpacity
      style={[styles.pill, active && styles.pillActive, active && color ? {borderColor: color} : null]}
      onPress={onPress}>
      <Text style={[styles.pillText, active && styles.pillTextActive]}>{label}</Text>
    </TouchableOpacity>
  );
}

function SourceBrowser({sources, onAdd}: {sources: Source[]; onAdd: (platform: PlatformId, channel: string) => void}) {
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
      if (url && request.navigationType === 'click' && addParsed(url)) {
        return false;
      }
      return true;
    },
    [addParsed],
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
    <View style={styles.screen}>
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
          injectedJavaScript={sourceBridgeScript}
          onMessage={handleMessage}
          onShouldStartLoadWithRequest={intercept}
        />
      </View>
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        style={styles.sourceTabs}
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

function ViewingScreen({
  streams,
  settings,
  volumes,
  onAdd,
  onRemove,
  onMove,
  onVolume,
  onSettings,
  auth,
  onAuth,
}: {
  streams: StreamItem[];
  settings: AppSettings;
  volumes: Record<string, number>;
  onAdd: (platform: PlatformId, channel: string) => void;
  onRemove: (id: string) => void;
  onMove: (index: number, target: number) => void;
  onVolume: (stream: StreamItem, volume: number) => void;
  onSettings: (patch: Partial<AppSettings>) => void;
  auth: AuthState;
  onAuth: (auth: AuthState) => void;
}) {
  const [adding, setAdding] = useState(false);
  const [focused, setFocused] = useState<StreamItem | null>(null);
  // reloadKey をインクリメントするとプレイヤー(native/iframe/web)が再マウントされ
  // ソース解決もやり直す。更新ボタン(全体/セル別)の実体。
  const [reloadKeys, setReloadKeys] = useState<Record<string, number>>({});
  const reloadStream = useCallback((id: string) => {
    setReloadKeys(current => ({...current, [id]: (current[id] ?? 0) + 1}));
  }, []);
  const reloadAll = useCallback(() => {
    setReloadKeys(current => {
      const next = {...current};
      streams.forEach(stream => {
        next[stream.id] = (next[stream.id] ?? 0) + 1;
      });
      return next;
    });
  }, [streams]);
  const columns = settings.layoutMode === 'grid' ? 2 : 1;
  const slots = useMemo(() => gridSlots(streams, settings.layoutMode), [settings.layoutMode, streams]);

  return (
    <View style={styles.screen}>
      <View style={styles.viewBody}>
        {streams.length === 0 ? (
          <View style={styles.empty}>
            <Text style={styles.emptyTitle}>配信がありません</Text>
            <Text style={styles.emptyText}>追加ボタン、ランキング、フォロー画面から配信を追加できます。</Text>
          </View>
        ) : (
          <ScrollView contentContainerStyle={styles.streamGrid}>
            {slots.map(({stream, index, width}) => (
              <View key={stream.id} style={[styles.streamCellWrap, {width}]}>
                <StreamCell
                  stream={stream}
                  settings={settings}
                  streamCount={streams.length}
                  volume={volumes[stream.id] ?? 1}
                  paused={focused?.id === stream.id}
                  muted={!settings.playAudio}
                  reloadKey={reloadKeys[stream.id] ?? 0}
                  index={index}
                  count={streams.length}
                  columns={columns}
                  onFocus={() => setFocused(stream)}
                  onReload={() => reloadStream(stream.id)}
                  onMove={onMove}
                  onRemove={onRemove}
                  onVolume={onVolume}
                  auth={auth}
                  onAuth={onAuth}
                />
              </View>
            ))}
          </ScrollView>
        )}
      </View>

      <View style={styles.viewBottomControls}>
        <View style={styles.iconSegment}>
          <TouchableOpacity
            style={[styles.iconSegmentButton, settings.layoutMode === 'stacked' && styles.iconSegmentButtonActive]}
            onPress={() => onSettings({layoutMode: 'stacked'})}>
            <Text style={[styles.iconSegmentText, settings.layoutMode === 'stacked' && styles.iconSegmentTextActive]}>▥</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.iconSegmentButton, settings.layoutMode === 'grid' && styles.iconSegmentButtonActive]}
            onPress={() => onSettings({layoutMode: 'grid'})}>
            <Text style={[styles.iconSegmentText, settings.layoutMode === 'grid' && styles.iconSegmentTextActive]}>▦</Text>
          </TouchableOpacity>
        </View>
        <View style={styles.viewBottomSpacer} />
        {streams.length > 0 && (
          <TouchableOpacity style={styles.bottomIconButton} onPress={reloadAll}>
            <Text style={styles.bottomIconText}>↻</Text>
          </TouchableOpacity>
        )}
        <TouchableOpacity style={styles.bottomIconButton} onPress={() => setAdding(true)}>
          <Text style={styles.bottomIconText}>＋</Text>
        </TouchableOpacity>
      </View>

      <AddStreamModal
        visible={adding}
        settings={settings}
        onClose={() => setAdding(false)}
        onAdd={onAdd}
      />
      <FocusModal
        stream={focused}
        settings={settings}
        streamCount={streams.length}
        volume={focused ? volumes[focused.id] ?? 1 : 1}
        muted={!settings.playAudio}
        reloadKey={focused ? reloadKeys[focused.id] ?? 0 : 0}
        onReload={() => focused && reloadStream(focused.id)}
        onVolume={onVolume}
        onClose={() => setFocused(null)}
        onRemove={onRemove}
        auth={auth}
        onAuth={onAuth}
      />
    </View>
  );
}

function gridSlots(streams: StreamItem[], layoutMode: AppSettings['layoutMode']): Array<{stream: StreamItem; index: number; width: '50%' | '100%'}> {
  if (layoutMode !== 'grid') {
    return streams.map((stream, index) => ({stream, index, width: '100%'}));
  }
  // 2列で詰め、奇数のときだけ最後の1本を全幅にする。
  // (旧実装は偶数だと末尾2本が全幅化し、2本=実質スタック表示になるバグがあった)
  const bigCount = streams.length % 2 === 0 ? 0 : 1;
  const pairedCount = Math.max(0, streams.length - bigCount);
  return streams.map((stream, index) => ({
    stream,
    index,
    width: index < pairedCount ? '50%' : '100%',
  }));
}

function StreamCell({
  stream,
  settings,
  streamCount,
  volume,
  paused,
  muted,
  reloadKey,
  index,
  count,
  columns,
  onFocus,
  onReload,
  onMove,
  onRemove,
  onVolume,
  auth,
  onAuth,
}: {
  stream: StreamItem;
  settings: AppSettings;
  streamCount: number;
  volume: number;
  paused: boolean;
  muted: boolean;
  reloadKey: number;
  index: number;
  count: number;
  columns: number;
  onFocus: () => void;
  onReload: () => void;
  onMove: (index: number, target: number) => void;
  onRemove: (id: string) => void;
  onVolume: (stream: StreamItem, volume: number) => void;
  auth: AuthState;
  onAuth: (auth: AuthState) => void;
}) {
  const info = platformInfo(stream.platform);
  const [commentOpen, setCommentOpen] = useState(false);
  const [commentText, setCommentText] = useState('');
  const [commentStatus, setCommentStatus] = useState('');
  const [cellLayout, setCellLayout] = useState({width: 0, height: 0});
  const [webViewerCount, setWebViewerCount] = useState<number | null>(null);
  const dragOriginRef = useRef(index);
  const dragCurrentRef = useRef(index);
  const webCommentRef = useRef<((text: string) => void) | null>(null);
  const {chromeVisible, showChrome} = useAutoHidingChrome(stream.id);
  const updateDragTarget = useCallback(
    (dx: number, dy: number) => {
      showChrome();
      const rowHeight = Math.max(80, cellLayout.height || 0);
      const colWidth = Math.max(80, cellLayout.width || 0);
      const rowDelta = Math.round(dy / rowHeight);
      const colDelta = columns > 1 ? Math.round(dx / colWidth) : 0;
      const target = Math.max(0, Math.min(count - 1, dragOriginRef.current + rowDelta * columns + colDelta));
      if (target !== dragCurrentRef.current) {
        onMove(dragCurrentRef.current, target);
        dragCurrentRef.current = target;
      }
    },
    [cellLayout.height, cellLayout.width, columns, count, onMove, showChrome],
  );
  const reorderResponder = useMemo(
    () =>
      PanResponder.create({
        onStartShouldSetPanResponder: () => true,
        onMoveShouldSetPanResponder: () => true,
        onPanResponderGrant: () => {
          showChrome();
          dragOriginRef.current = index;
          dragCurrentRef.current = index;
        },
        onPanResponderMove: (_, gesture) => updateDragTarget(gesture.dx, gesture.dy),
        onPanResponderRelease: (_, gesture) => {
          updateDragTarget(gesture.dx, gesture.dy);
        },
      }),
    [index, showChrome, updateDragTarget],
  );
  const submitComment = useCallback(() => {
    const text = commentText.trim();
    if (!text) {
      return;
    }
    setCommentStatus('送信中');
    postStreamComment(auth, stream, text)
      .then(nextAuth => {
        onAuth(nextAuth);
        setCommentText('');
        setCommentStatus('送信しました');
        setTimeout(() => setCommentOpen(false), 450);
      })
      .catch(error => {
        if (webCommentRef.current) {
          webCommentRef.current(text);
          setCommentText('');
          setCommentStatus('Webチャットへ送信しました');
          setTimeout(() => setCommentOpen(false), 450);
          return;
        }
        setCommentStatus(error instanceof Error ? error.message : String(error));
      });
  }, [auth, commentText, onAuth, stream]);

  return (
    <View style={styles.streamCell} onLayout={event => setCellLayout(event.nativeEvent.layout)}>
      <View style={styles.player} onTouchStart={showChrome}>
        <StreamPlayer
          stream={stream}
          settings={settings}
          streamCount={streamCount}
          paused={paused}
          muted={muted || volume <= 0}
          volume={volume}
          reloadKey={reloadKey}
          onWebCommentBridge={send => {
            webCommentRef.current = send;
          }}
          onViewerCount={setWebViewerCount}
        />
        <View style={styles.playerChrome} pointerEvents="box-none">
          {!chromeVisible && <Pressable style={styles.chromeRevealTouch} onPress={showChrome} />}
          {settings.showViewerCount && <ViewerCountBadge stream={stream} externalCount={webViewerCount} visible={chromeVisible} />}
          <View
            style={[styles.autoHideChrome, !chromeVisible && styles.autoHideChromeHidden]}
            pointerEvents={chromeVisible ? 'box-none' : 'none'}>
            <View style={styles.cellTopControls} pointerEvents="box-none">
              <TouchableOpacity style={styles.overlayButton} onPress={() => setCommentOpen(current => !current)}>
                <Text style={styles.overlayIcon}>□</Text>
              </TouchableOpacity>
              <TouchableOpacity style={styles.overlayButton} onPress={onFocus}>
                <Text style={styles.overlayIcon}>↗</Text>
              </TouchableOpacity>
              <TouchableOpacity style={styles.overlayButton} onPress={onReload}>
                <Text style={styles.overlayIcon}>↻</Text>
              </TouchableOpacity>
              <TouchableOpacity style={styles.overlayButton} onPress={() => onRemove(stream.id)}>
                <Text style={styles.overlayIcon}>×</Text>
              </TouchableOpacity>
            </View>
            <VolumeOverlay stream={stream} volume={volume} color={info.color} onVolume={onVolume} onInteract={showChrome} />
            <View style={styles.reorderHandle} {...reorderResponder.panHandlers}>
              <Text style={styles.reorderIcon}>≡</Text>
            </View>
          </View>
          {commentOpen && (
            <View style={styles.commentBar}>
              <TextInput
                value={commentText}
                onChangeText={setCommentText}
                autoCapitalize="none"
                autoCorrect={false}
                placeholder="コメント"
                placeholderTextColor="rgba(255,255,255,0.55)"
                style={styles.commentInput}
                returnKeyType="send"
                onSubmitEditing={submitComment}
              />
              <TouchableOpacity style={styles.commentSend} onPress={submitComment}>
                <Text style={styles.commentSendText}>送信</Text>
              </TouchableOpacity>
              {!!commentStatus && <Text style={styles.commentStatus} numberOfLines={1}>{commentStatus}</Text>}
            </View>
          )}
        </View>
      </View>
    </View>
  );
}

function StreamPlayer({
  stream,
  settings,
  streamCount,
  paused,
  muted,
  volume,
  reloadKey,
  onWebCommentBridge,
  onViewerCount,
}: {
  stream: StreamItem;
  settings: AppSettings;
  streamCount: number;
  paused: boolean;
  muted: boolean;
  volume: number;
  reloadKey: number;
  onWebCommentBridge?: (send: ((text: string) => void) | null) => void;
  onViewerCount?: (count: number) => void;
}) {
  const [source, setSource] = useState<PlaybackSource | null>(null);
  const [, setPlayerStatus] = useState('待機中');
  const webRef = useRef<WebView>(null);
  // ネイティブプレイヤーの error/ended を受けてのデバウンス自動復旧。
  // iOS の .multiViewPlaybackErrored と同じく 45 秒に 1 回までに制限してループを防ぐ。
  const [autoReloadTick, setAutoReloadTick] = useState(0);
  const lastAutoReloadRef = useRef(0);
  const scheduleAutoReload = useCallback(() => {
    const now = Date.now();
    if (now - lastAutoReloadRef.current < 45000) {
      return;
    }
    lastAutoReloadRef.current = now;
    setTimeout(() => setAutoReloadTick(tick => tick + 1), 1500);
  }, []);

  const handleWebMessage = useCallback(
    (event: WebViewMessageEvent) => {
      try {
        const payload = JSON.parse(event.nativeEvent.data);
        const count = Number(payload?.count);
        if (payload?.type === 'viewerCount' && Number.isFinite(count) && count >= 0) {
          onViewerCount?.(Math.round(count));
        }
      } catch {
        // Ignore bridge noise from websites.
      }
    },
    [onViewerCount],
  );

  useEffect(() => {
    if (stream.platform === 'niconico') {
      // ニコ生はネイティブ視聴セッション(NiconicoNativePlayer)が自前で扱う。
      return;
    }
    let cancelled = false;
    setSource(null);
    setPlayerStatus('取得中');
    resolvePlaybackSource(stream, settings, streamCount)
      .then(next => {
        if (!cancelled) {
          setSource(next);
          setPlayerStatus(next.status);
        }
      })
      .catch(error => {
        if (!cancelled) {
          setSource({
            kind: 'error',
            label: '取得失敗',
            status: 'エラー',
            reason: error instanceof Error ? error.message : String(error),
            fallbackUrl: webStreamURL(stream),
          });
          setPlayerStatus('エラー');
        }
      });
    return () => {
      cancelled = true;
    };
  }, [stream, settings, streamCount, reloadKey, autoReloadTick]);

  useEffect(() => {
    if (!onWebCommentBridge) {
      return;
    }
    if (!source || (source.kind !== 'web' && source.kind !== 'youtube-iframe')) {
      onWebCommentBridge(null);
      return;
    }
    onWebCommentBridge(text => injectWebComment(webRef.current, text));
    return () => onWebCommentBridge(null);
  }, [onWebCommentBridge, source, stream.platform]);

  useEffect(() => {
    if (!source || source.kind === 'native') {
      return;
    }
    const effectiveVolume = muted ? 0 : volume;
    const command = `
      (function(){
        try { window.mvSetVolume && window.mvSetVolume(${effectiveVolume}); } catch(e) {}
        try { ${paused ? 'window.mvPause && window.mvPause();' : 'window.mvPlay && window.mvPlay();'} } catch(e) {}
        try {
          document.querySelectorAll('video,audio').forEach(function(media){
            media.muted=${effectiveVolume <= 0};
            media.volume=${effectiveVolume};
            ${paused ? 'media.pause();' : 'var p=media.play&&media.play(); if(p&&p.catch)p.catch(function(){});'}
          });
        } catch(e) {}
      })();
      true;
    `;
    webRef.current?.injectJavaScript(command);
  }, [source, paused, muted, volume]);

  if (stream.platform === 'niconico') {
    return (
      <NiconicoNativePlayer
        stream={stream}
        settings={settings}
        streamCount={streamCount}
        paused={paused}
        muted={muted}
        volume={volume}
        reloadKey={reloadKey + autoReloadTick}
        onViewerCount={onViewerCount}
      />
    );
  }

  if (!source) {
    return (
      <View style={styles.playerPlaceholder}>
        <ActivityIndicator color="#7ab7ff" />
        <Text style={styles.playerStatus}>取得中</Text>
      </View>
    );
  }

  if (source.kind === 'native') {
    return (
      <>
        <NativeHlsPlayer
          key={`${source.url}:${reloadKey}:${autoReloadTick}`}
          style={styles.nativePlayer}
          sourceUrl={source.url}
          headers={source.headers}
          paused={paused}
          muted={muted}
          volume={volume}
          liveTargetOffsetMs={source.liveTargetOffsetMs}
          maxBitrate={effectiveQuality(settings, streamCount) === 'economy' ? 900000 : 0}
          resizeMode="contain"
          onPlayerEvent={event => {
            const payload = event.nativeEvent;
            setPlayerStatus(payload.type === 'error' ? `エラー: ${payload.message}` : payload.message);
            if (payload.type === 'error' || payload.message === 'ended') {
              scheduleAutoReload();
            }
          }}
        />
        <DanmakuOverlay stream={stream} settings={settings} />
      </>
    );
  }

  if (source.kind === 'youtube-iframe') {
    return (
      <>
        <WebView
          key={`${source.videoId}:${reloadKey}`}
          ref={webRef}
          source={{html: youtubeIframeHTML(source.videoId), baseUrl: 'https://tonton888115.github.io/MultiView/'}}
          javaScriptEnabled
          domStorageEnabled
          allowsInlineMediaPlayback
          mediaPlaybackRequiresUserAction={false}
          setSupportMultipleWindows={false}
          style={styles.webPlayer}
        />
        <WebView
          key={`viewer:${source.videoId}:${reloadKey}`}
          source={{uri: `https://m.youtube.com/watch?v=${encodeURIComponent(source.videoId)}`}}
          userAgent={mobileUserAgent}
          javaScriptEnabled
          domStorageEnabled
          sharedCookiesEnabled
          thirdPartyCookiesEnabled
          allowsInlineMediaPlayback
          mediaPlaybackRequiresUserAction
          setSupportMultipleWindows={false}
          injectedJavaScript={webFallbackScript(settings.blockWebAds, stream.platform)}
          onShouldStartLoadWithRequest={request => !(settings.blockWebAds && isAdBlockedURL(request.url))}
          onMessage={handleWebMessage}
          style={styles.hiddenBridgeWeb}
        />
        <DanmakuOverlay stream={stream} settings={settings} />
      </>
    );
  }

  if (source.kind === 'web' || (source.kind === 'error' && source.fallbackUrl)) {
    const url = source.kind === 'web' ? source.url : source.fallbackUrl ?? 'about:blank';
    return (
      <>
        <WebView
          key={`${url}:${reloadKey}`}
          ref={webRef}
          source={{uri: url}}
          userAgent={mobileUserAgent}
          javaScriptEnabled
          domStorageEnabled
          sharedCookiesEnabled
          thirdPartyCookiesEnabled
          allowsInlineMediaPlayback
          mediaPlaybackRequiresUserAction={false}
          setSupportMultipleWindows={false}
          injectedJavaScript={webFallbackScript(settings.blockWebAds, stream.platform)}
          onShouldStartLoadWithRequest={request => !(settings.blockWebAds && isAdBlockedURL(request.url))}
          onMessage={handleWebMessage}
          style={styles.webPlayer}
        />
        <DanmakuOverlay stream={stream} settings={settings} />
        {source.kind === 'error' && <PlayerBadge source={source} status={source.reason} warning />}
      </>
    );
  }

  return (
    <View style={styles.playerPlaceholder}>
      <Text style={styles.playerStatus}>{source.reason}</Text>
    </View>
  );
}

function NiconicoNativePlayer({
  stream,
  settings,
  streamCount,
  paused,
  muted,
  volume,
  reloadKey,
  onViewerCount,
}: {
  stream: StreamItem;
  settings: AppSettings;
  streamCount: number;
  paused: boolean;
  muted: boolean;
  volume: number;
  reloadKey: number;
  onViewerCount?: (count: number) => void;
}) {
  const [hls, setHls] = useState<{url: string; cookieHeader?: string} | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    // 番組/品質/低遅延/更新 が変わったらセッションをやり直す。
    setHls(null);
    setFailed(false);
  }, [stream.channel, settings.wifiQuality, settings.niconicoLowLatency, reloadKey]);

  const onSessionMessage = useCallback(
    (event: WebViewMessageEvent) => {
      let payload: any;
      try {
        payload = JSON.parse(event.nativeEvent.data);
      } catch {
        return;
      }
      if (payload?.type === 'niconicoStream' && typeof payload.hlsUrl === 'string') {
        setHls({url: payload.hlsUrl, cookieHeader: payload.cookies || undefined});
      } else if (payload?.type === 'niconicoComment' && typeof payload.text === 'string') {
        pushNiconicoComment(stream.channel, {text: payload.text});
      } else if (payload?.type === 'niconicoEvent' && typeof payload.text === 'string') {
        // ギフト/ニコニ広告/通知。死にトグルだった各設定で表示可否を制御する。
        const allowed =
          (payload.kind === 'gift' && settings.showGiftEffects && settings.niconicoShowGift) ||
          (payload.kind === 'nicoad' && settings.niconicoShowNicoad) ||
          (payload.kind === 'notification' && settings.niconicoShowNotification);
        if (allowed) {
          pushNiconicoComment(stream.channel, {text: payload.text});
        }
      } else if (payload?.type === 'niconicoError' || payload?.type === 'niconicoEnded') {
        setFailed(true);
      }
    },
    [
      stream.channel,
      settings.showGiftEffects,
      settings.niconicoShowGift,
      settings.niconicoShowNicoad,
      settings.niconicoShowNotification,
    ],
  );

  // niconico は RN の直接 fetch/WS を拒否するため、視聴セッションは niconico オリジンを
  // 読み込んだ隠し WebView 内で実行し、HLS uri を postMessage で受け取る(keepSeatも内部で継続)。
  const sessionWebView =
    !failed ? (
      <WebView
        key={`niconico-session:${stream.channel}:${reloadKey}`}
        source={{uri: niconicoOriginURL}}
        userAgent={desktopUserAgent}
        javaScriptEnabled
        domStorageEnabled
        sharedCookiesEnabled
        thirdPartyCookiesEnabled
        setSupportMultipleWindows={false}
        injectedJavaScript={niconicoSessionScript(stream.channel, niconicoQuality(settings))}
        onMessage={onSessionMessage}
        style={styles.hiddenBridgeWeb}
      />
    ) : null;

  if (hls) {
    return (
      <>
        {sessionWebView}
        <NativeHlsPlayer
          key={`${hls.url}:${reloadKey}`}
          style={styles.nativePlayer}
          sourceUrl={hls.url}
          headers={
            hls.cookieHeader
              ? {Cookie: hls.cookieHeader, 'User-Agent': mobileUserAgent}
              : {'User-Agent': mobileUserAgent}
          }
          paused={paused}
          muted={muted}
          volume={volume}
          liveTargetOffsetMs={settings.niconicoLowLatency ? 2000 : 6000}
          maxBitrate={effectiveQuality(settings, streamCount) === 'economy' ? 900000 : 0}
          resizeMode="contain"
        />
        <DanmakuOverlay stream={stream} settings={settings} />
      </>
    );
  }

  if (failed) {
    return (
      <>
        <WebView
          key={`niconico-web:${reloadKey}`}
          source={{uri: webStreamURL(stream)}}
          userAgent={mobileUserAgent}
          javaScriptEnabled
          domStorageEnabled
          sharedCookiesEnabled
          thirdPartyCookiesEnabled
          allowsInlineMediaPlayback
          mediaPlaybackRequiresUserAction={false}
          setSupportMultipleWindows={false}
          injectedJavaScript={webFallbackScript(settings.blockWebAds, 'niconico')}
          onShouldStartLoadWithRequest={request => !(settings.blockWebAds && isAdBlockedURL(request.url))}
          onMessage={event => {
            try {
              const payload = JSON.parse(event.nativeEvent.data);
              const count = Number(payload?.count);
              if (payload?.type === 'viewerCount' && Number.isFinite(count) && count >= 0) {
                onViewerCount?.(Math.round(count));
              }
            } catch {
              // ignore bridge noise
            }
          }}
          style={styles.webPlayer}
        />
        <DanmakuOverlay stream={stream} settings={settings} />
      </>
    );
  }

  return (
    <>
      {sessionWebView}
      <View style={styles.playerPlaceholder}>
        <ActivityIndicator color="#7ab7ff" />
        <Text style={styles.playerStatus}>ニコ生接続中</Text>
      </View>
    </>
  );
}

function PlayerBadge({source, status, warning}: {source: PlaybackSource; status: string; warning?: boolean}) {
  return (
    <View style={[styles.playerBadge, warning && styles.playerBadgeWarning]}>
      <Text style={styles.playerBadgeText} numberOfLines={1}>
        {source.label} / {status}
      </Text>
    </View>
  );
}

function VolumeOverlay({
  stream,
  volume,
  color,
  onVolume,
  onInteract,
  mode = 'cell',
}: {
  stream: StreamItem;
  volume: number;
  color: string;
  onVolume: (stream: StreamItem, volume: number) => void;
  onInteract?: () => void;
  mode?: 'cell' | 'focus';
}) {
  const [height, setHeight] = useState(0);
  const updateFromY = useCallback(
    (locationY: number) => {
      if (height <= 0) {
        return;
      }
      onInteract?.();
      const next = 1 - Math.max(0, Math.min(height, locationY)) / height;
      onVolume(stream, next);
    },
    [height, onInteract, onVolume, stream],
  );
  const responder = useMemo(
    () =>
      PanResponder.create({
        onStartShouldSetPanResponder: () => true,
        onMoveShouldSetPanResponder: () => true,
        onPanResponderGrant: event => updateFromY(event.nativeEvent.locationY),
        onPanResponderMove: event => updateFromY(event.nativeEvent.locationY),
      }),
    [updateFromY],
  );

  return (
    <View
      style={[styles.volumeOverlay, mode === 'focus' ? styles.focusVolumeOverlay : styles.cellVolumeOverlay]}
      onLayout={event => setHeight(event.nativeEvent.layout.height)}
      {...responder.panHandlers}>
      <View style={styles.volumeTrack}>
        <View style={[styles.volumeLevel, {height: `${Math.round(volume * 100)}%`, backgroundColor: color}]} />
        <View style={[styles.volumeThumb, {bottom: `${Math.round(volume * 100)}%`}]} />
      </View>
      <Text style={styles.volumeIcon}>♪</Text>
    </View>
  );
}

function ViewerCountBadge({
  stream,
  externalCount,
  visible,
}: {
  stream: StreamItem;
  externalCount?: number | null;
  visible: boolean;
}) {
  const [count, setCount] = useState<number | null>(null);
  const opacity = useRef(new Animated.Value(0)).current;
  const inFlightRef = useRef(false);
  const hideTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const clearHideTimer = useCallback(() => {
    if (hideTimerRef.current) {
      clearTimeout(hideTimerRef.current);
      hideTimerRef.current = null;
    }
  }, []);

  const reveal = useCallback(() => {
    clearHideTimer();
    Animated.timing(opacity, {
      toValue: 1,
      duration: 140,
      useNativeDriver: true,
    }).start();
    hideTimerRef.current = setTimeout(() => {
      Animated.timing(opacity, {
        toValue: 0,
        duration: 520,
        useNativeDriver: true,
      }).start();
      hideTimerRef.current = null;
    }, chromeAutoHideDelayMs);
  }, [clearHideTimer, opacity]);

  useEffect(() => {
    if (externalCount != null && externalCount >= 0) {
      setCount(Math.round(externalCount));
      reveal();
    }
  }, [externalCount, reveal]);

  useEffect(() => {
    setCount(null);
    opacity.setValue(0);
    clearHideTimer();
  }, [clearHideTimer, opacity, stream.id]);

  useEffect(() => {
    if (visible && count != null && count >= 0) {
      reveal();
    }
  }, [count, reveal, visible]);

  useEffect(() => () => clearHideTimer(), [clearHideTimer]);

  useEffect(() => {
    let cancelled = false;
    const refresh = () => {
      if (inFlightRef.current) {
        return;
      }
      inFlightRef.current = true;
      fetchViewerCount(stream)
        .then(value => {
          if (!cancelled && value != null) {
            setCount(value);
            reveal();
          }
        })
        .catch(() => {
          // Keep the last known count, including values bridged from a YouTube WebView.
        })
        .finally(() => {
          inFlightRef.current = false;
        });
    };
    refresh();
    const timer = setInterval(refresh, 30000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [reveal, stream]);

  if (count == null || count < 0) {
    return null;
  }

  return (
    <Animated.View style={[styles.viewerBadge, {opacity}]} pointerEvents="none">
      <Text style={styles.viewerBadgeIcon}>◇</Text>
      <Text style={styles.viewerBadgeText}>{count}人</Text>
    </Animated.View>
  );
}

async function fetchViewerCount(stream: StreamItem): Promise<number | null> {
  switch (stream.platform) {
    case 'kick':
      return fetchKickViewerCount(stream.channel);
    case 'twitch':
      return fetchTwitchViewerCount(stream.channel);
    case 'youtube':
      return fetchYouTubeViewerCount(stream.channel);
    case 'niconico':
      return fetchHTMLViewerCount(webStreamURL(stream), niconicoCurrentViewerKeys);
    case 'twitcasting':
      return fetchHTMLViewerCount(webStreamURL(stream), ['current_view_count', 'currentViewerCount', 'current_viewer_count', 'viewer_count', 'viewerCount', 'viewers']);
  }
}

async function fetchKickViewerCount(rawChannel: string): Promise<number | null> {
  const channel = rawChannel.trim().replace(/^@+/, '').split(/[/?#\s]/)[0];
  const response = await fetch(`https://kick.com/api/v2/channels/${encodeURIComponent(channel)}`, {
    headers: {'User-Agent': desktopUserAgent, Accept: 'application/json'},
  });
  const json = await response.json();
  return json?.livestream
    ? numberFromKeys(json.livestream, ['viewer_count', 'viewerCount', 'viewers', 'viewersCount', 'currentViewers'])
    : null;
}

async function fetchTwitchViewerCount(rawChannel: string): Promise<number | null> {
  const channel = rawChannel.trim().replace(/^[@#]+/, '').split(/[/?#\s]/)[0].toLowerCase();
  const response = await fetch('https://gql.twitch.tv/gql', {
    method: 'POST',
    headers: {
      'Client-ID': 'kimne78kx3ncx6brgo4mv6wki5h1ko',
      'Content-Type': 'application/json',
      'User-Agent': desktopUserAgent,
    },
    body: JSON.stringify({
      operationName: 'ViewerCount',
      variables: {login: channel},
      query: 'query ViewerCount($login: String!) { user(login: $login) { stream { viewersCount } } }',
    }),
  });
  const json = await response.json();
  return toNumber(json?.data?.user?.stream?.viewersCount);
}

async function fetchYouTubeViewerCount(rawChannel: string): Promise<number | null> {
  let videoId = youtubeVideoId(rawChannel);
  try {
    videoId = videoId ?? await resolveLiveYouTubeVideoID(rawChannel);
  } catch {
    videoId = videoId ?? null;
  }
  if (videoId) {
    const firstCount = await firstViewerCount([
      fetchYouTubePlayerViewerCount(videoId),
      fetchYouTubeWatchViewerCount(videoId),
    ]);
    if (firstCount != null) {
      return firstCount;
    }
  }
  const url = youtubeViewerURL(rawChannel);
  if (!url) {
    return null;
  }
  const response = await fetchWithTimeout(url, {headers: {'User-Agent': desktopUserAgent}}, youtubeViewerFetchTimeoutMs);
  return youtubeViewerCountFromText(await response.text());
}

async function firstViewerCount(promises: Array<Promise<number | null>>): Promise<number | null> {
  return new Promise(resolve => {
    let pending = promises.length;
    let resolved = false;
    const settle = (value: number | null) => {
      if (!resolved && value != null) {
        resolved = true;
        resolve(value);
        return;
      }
      pending -= 1;
      if (!resolved && pending <= 0) {
        resolved = true;
        resolve(null);
      }
    };
    for (const promise of promises) {
      promise.then(settle).catch(() => settle(null));
    }
  });
}

async function fetchYouTubeWatchViewerCount(videoId: string): Promise<number | null> {
  try {
    const mobileResponse = await fetchWithTimeout(
      `https://m.youtube.com/watch?v=${encodeURIComponent(videoId)}`,
      {headers: {'User-Agent': mobileUserAgent, 'Accept-Language': 'ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6'}},
      youtubeViewerFetchTimeoutMs,
    );
    const mobileCount = youtubeViewerCountFromText(await mobileResponse.text());
    if (mobileCount != null) {
      return mobileCount;
    }
  } catch {
    // Try the desktop watch page below.
  }
  try {
    const response = await fetchWithTimeout(
      `https://www.youtube.com/watch?v=${encodeURIComponent(videoId)}`,
      {headers: {'User-Agent': desktopUserAgent}},
      youtubeViewerFetchTimeoutMs,
    );
    return youtubeViewerCountFromText(await response.text());
  } catch {
    return null;
  }
}

async function fetchYouTubePlayerViewerCount(videoId: string): Promise<number | null> {
  for (const client of youtubeClients()) {
    try {
      const response = await fetchWithTimeout(
        'https://youtubei.googleapis.com/youtubei/v1/player',
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': client.userAgent,
            'X-YouTube-Client-Name': client.headerClientName,
            'X-YouTube-Client-Version': client.version,
            'Accept-Language': 'ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6',
          },
          body: JSON.stringify({
            context: client.context,
            videoId,
            contentCheckOk: true,
            racyCheckOk: true,
          }),
        },
        youtubePlayerViewerFetchTimeoutMs,
      );
      if (!response.ok) {
        continue;
      }
      const count = youtubePlayerViewerCountFromJSON(await response.json());
      if (count != null) {
        return count;
      }
    } catch {
      // Try the next client/fallback path.
    }
  }
  return null;
}

async function fetchHTMLViewerCount(url: string, keys: string[]): Promise<number | null> {
  const response = await fetchWithTimeout(url, {headers: {'User-Agent': desktopUserAgent}}, youtubeViewerFetchTimeoutMs);
  const html = await response.text();
  return numberFromText(decodeHTMLEntities(html), keys);
}

async function fetchWithTimeout(url: string, init: RequestInit, timeoutMs: number): Promise<Response> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<Response>((_, reject) => {
    timer = setTimeout(() => {
      reject(new Error(`Request timed out after ${timeoutMs}ms`));
    }, timeoutMs);
  });
  try {
    return await Promise.race([fetch(url, init), timeout]);
  } finally {
    if (timer) {
      clearTimeout(timer);
    }
  }
}

function youtubeViewerURL(raw: string): string | null {
  const value = raw.trim();
  const id = value.match(/^[A-Za-z0-9_-]{11}$/)?.[0]
    ?? value.match(/[?&]v=([A-Za-z0-9_-]{11})/)?.[1]
    ?? value.match(/youtu\.be\/([A-Za-z0-9_-]{11})/)?.[1]
    ?? value.match(/\/(?:live|embed|shorts)\/([A-Za-z0-9_-]{11})/)?.[1];
  if (id) {
    return `https://www.youtube.com/watch?v=${encodeURIComponent(id)}`;
  }
  if (value.startsWith('@')) {
    return `https://www.youtube.com/${encodeURIComponent(value)}/live`;
  }
  return `https://www.youtube.com/@${encodeURIComponent(value.replace(/^@+/, ''))}/live`;
}

function numberFromKeys(value: unknown, keys: string[]): number | null {
  if (!value) {
    return null;
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      const count = numberFromKeys(item, keys);
      if (count != null) {
        return count;
      }
    }
    return null;
  }
  if (typeof value === 'object') {
    const object = value as Record<string, unknown>;
    for (const key of keys) {
      const count = toNumber(object[key]);
      if (count != null) {
        return count;
      }
    }
    for (const item of Object.values(object)) {
      const count = numberFromKeys(item, keys);
      if (count != null) {
        return count;
      }
    }
  }
  return null;
}

function numberFromText(text: string, keys: string[]): number | null {
  for (const key of keys) {
    const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const match = text.match(new RegExp(`"${escaped}"\\s*:?\\s*"?([0-9,]+)"?`, 'i'));
    const count = toNumber(match?.[1]);
    if (count != null) {
      return count;
    }
  }
  return null;
}

function youtubeViewerCountFromJSON(value: unknown): number | null {
  return youtubePlayerViewerCountFromJSON(value)
    ?? youtubePrimaryViewerCountFromJSON(value)
    ?? youtubeMobileViewerCountFromJSON(value)
    ?? numberFromKeys(value, youtubeViewerKeys);
}

function youtubePlayerViewerCountFromJSON(value: unknown): number | null {
  const object = value as any;
  return toNumber(object?.videoDetails?.concurrentViewers)
    ?? toNumber(object?.microformat?.playerMicroformatRenderer?.liveBroadcastDetails?.concurrentViewers);
}

function youtubeViewerCountFromText(text: string): number | null {
  const decoded = decodeHTMLEntities(text);
  const direct = numberFromText(decoded, youtubeViewerKeys);
  if (direct != null) {
    return direct;
  }
  for (const token of ['ytInitialPlayerResponse', 'ytInitialData']) {
    const assigned = jsonAssignedValueAfterToken(token, decoded);
    if (assigned) {
      try {
        const count = youtubeViewerCountFromJSON(JSON.parse(assigned));
        if (count != null) {
          return count;
        }
      } catch {
        const count = youtubeMobileViewerCountFromTextBlob(assigned);
        if (count != null) {
          return count;
        }
      }
    }
    const json = jsonObjectStringAfterToken(token, decoded);
    if (!json) {
      continue;
    }
    try {
      const count = youtubeViewerCountFromJSON(JSON.parse(json));
      if (count != null) {
        return count;
      }
    } catch {
      // Try the next embedded object.
    }
  }
  return null;
}

function youtubeMobileViewerCountFromTextBlob(text: string): number | null {
  if (!text.includes('"liveIndicatorText"')) {
    return null;
  }
  const match = text.match(
    /"slimVideoInformationRenderer"\s*:\s*\{[\s\S]{0,6000}?"collapsedSubtitle"\s*:\s*\{\s*"runs"\s*:\s*\[\s*\{\s*"text"\s*:\s*"([0-9][0-9,\s\u00a0]*)"\s*\}\s*,/,
  ) ?? text.match(
    /"slimVideoInformationRenderer"\s*:\s*\{[\s\S]{0,6000}?"expandedSubtitle"\s*:\s*\{\s*"runs"\s*:\s*\[\s*\{\s*"text"\s*:\s*"([0-9][0-9,\s\u00a0]*)"\s*\}\s*,/,
  );
  return toPlainNumber(match?.[1]);
}

function youtubeMobileViewerCountFromJSON(value: unknown): number | null {
  const object = value as any;
  const liveIndicator = object?.playerOverlays?.playerOverlayRenderer?.liveIndicatorText;
  const contents = object?.contents?.singleColumnWatchNextResults?.results?.results?.contents;
  if (!liveIndicator || !Array.isArray(contents)) {
    return null;
  }
  for (const item of contents) {
    const sectionContents = item?.slimVideoMetadataSectionRenderer?.contents;
    if (!Array.isArray(sectionContents)) {
      continue;
    }
    for (const sectionItem of sectionContents) {
      const info = sectionItem?.slimVideoInformationRenderer;
      const subtitles = [info?.collapsedSubtitle, info?.expandedSubtitle];
      for (const subtitle of subtitles) {
        const runs = subtitle?.runs;
        if (Array.isArray(runs) && runs.length > 1) {
          const count = toPlainNumber(runs[0]?.text);
          if (count != null) {
            return count;
          }
        }
      }
    }
  }
  return null;
}

function youtubePrimaryViewerCountFromJSON(value: unknown): number | null {
  const object = value as any;
  const contents = object?.contents?.twoColumnWatchNextResults?.results?.results?.contents;
  if (!Array.isArray(contents)) {
    return null;
  }
  for (const item of contents) {
    const renderer = item?.videoPrimaryInfoRenderer?.viewCount?.videoViewCountRenderer;
    const count = youtubeVideoViewCountRendererCount(renderer);
    if (count != null) {
      return count;
    }
  }
  return null;
}

function youtubeVideoViewCountRendererCount(renderer: any): number | null {
  if (!renderer || renderer.isLive !== true) {
    return null;
  }
  return toNumber(renderer.originalViewCount);
}

function jsonAssignedValueAfterToken(token: string, text: string): string | null {
  const marker = `var ${token} =`;
  const markerIndex = text.indexOf(marker);
  if (markerIndex < 0) {
    return null;
  }
  let index = markerIndex + marker.length;
  while (/\s/.test(text[index] ?? '')) {
    index += 1;
  }
  const quote = text[index];
  if (quote === '"' || quote === "'") {
    let escaping = false;
    let raw = '';
    for (index += 1; index < text.length; index += 1) {
      const character = text[index];
      if (escaping) {
        raw += `\\${character}`;
        escaping = false;
      } else if (character === '\\') {
        escaping = true;
      } else if (character === quote) {
        return decodeJavaScriptStringLiteral(raw);
      } else {
        raw += character;
      }
    }
    return null;
  }
  if (text[index] === '{') {
    return jsonObjectStringAt(index, text);
  }
  return null;
}

function jsonObjectStringAfterToken(token: string, text: string): string | null {
  let position = 0;
  while (position < text.length) {
    const tokenIndex = text.indexOf(token, position);
    if (tokenIndex < 0) {
      return null;
    }
    const start = text.indexOf('{', tokenIndex + token.length);
    if (start < 0) {
      return null;
    }
    const json = jsonObjectStringAt(start, text);
    if (json) {
      return json;
    }
    position = tokenIndex + token.length;
  }
  return null;
}

function jsonObjectStringAt(start: number, text: string): string | null {
  let depth = 0;
  let inString = false;
  let escaping = false;
  for (let index = start; index < text.length; index += 1) {
    const character = text[index];
    if (inString) {
      if (escaping) {
        escaping = false;
      } else if (character === '\\') {
        escaping = true;
      } else if (character === '"') {
        inString = false;
      }
    } else if (character === '"') {
      inString = true;
    } else if (character === '{') {
      depth += 1;
    } else if (character === '}') {
      depth -= 1;
      if (depth === 0) {
        return text.slice(start, index + 1);
      }
    }
  }
  return null;
}

function decodeJavaScriptStringLiteral(text: string): string {
  return text
    .replace(/\\x([0-9a-fA-F]{2})/g, (_, hex: string) => String.fromCharCode(parseInt(hex, 16)))
    .replace(/\\u([0-9a-fA-F]{4})/g, (_, hex: string) => String.fromCharCode(parseInt(hex, 16)))
    .replace(/\\n/g, '\\n')
    .replace(/\\r/g, '\\r')
    .replace(/\\t/g, '\\t')
    .replace(/\\([^"\\/bfnrtu])/g, '$1')
    .replace(/\\\//g, '/')
    .replace(/\\"/g, '"')
    .replace(/\\'/g, "'")
    .replace(/\\\\/g, '\\');
}

function decodeHTMLEntities(text: string): string {
  return text
    .replace(/&quot;/g, '"')
    .replace(/&#34;/g, '"')
    .replace(/&#x22;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#x27;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&');
}

function toNumber(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.max(0, Math.round(value));
  }
  if (typeof value === 'string') {
    const parsed = Number(value.replace(/[,人\s]/g, ''));
    return Number.isFinite(parsed) ? Math.max(0, Math.round(parsed)) : null;
  }
  return null;
}

function toPlainNumber(value: unknown): number | null {
  if (typeof value === 'number') {
    return toNumber(value);
  }
  if (typeof value !== 'string' || !/^\s*[0-9][0-9,\s\u00a0]*\s*$/.test(value)) {
    return null;
  }
  return toNumber(value);
}

function AddStreamModal({
  visible,
  settings,
  onClose,
  onAdd,
}: {
  visible: boolean;
  settings: AppSettings;
  onClose: () => void;
  onAdd: (platform: PlatformId, channel: string) => void;
}) {
  const order = orderedPlatforms(settings.platformOrder);
  const [platform, setPlatform] = useState<PlatformId>(order[0]);
  const [text, setText] = useState('');
  const info = platformInfo(platform);

  useEffect(() => {
    if (!order.includes(platform)) {
      setPlatform(order[0]);
    }
  }, [order, platform]);

  const submit = () => {
    const value = text.trim();
    if (!value) {
      return;
    }
    onAdd(platform, value);
    setText('');
    onClose();
  };

  return (
    <Modal visible={visible} animationType="slide" onRequestClose={onClose}>
      <SafeAreaView style={styles.modal}>
        <View style={styles.modalHeader}>
          <Text style={styles.modalTitle}>配信を追加</Text>
          <TouchableOpacity onPress={onClose}>
            <Text style={styles.closeText}>閉じる</Text>
          </TouchableOpacity>
        </View>
        <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.sourceTabs}>
          {order.map(id => {
            const item = platformInfo(id);
            return (
              <Pill
                key={item.id}
                active={platform === item.id}
                color={item.color}
                label={item.label}
                onPress={() => setPlatform(item.id)}
              />
            );
          })}
        </ScrollView>
        <TextInput
          value={text}
          onChangeText={setText}
          autoCapitalize="none"
          autoCorrect={false}
          placeholder={info.hint}
          placeholderTextColor="#7d8794"
          style={styles.input}
        />
        <TouchableOpacity style={styles.fullButton} onPress={submit}>
          <Text style={styles.fullButtonText}>追加</Text>
        </TouchableOpacity>
      </SafeAreaView>
    </Modal>
  );
}

function FocusModal({
  stream,
  settings,
  streamCount,
  volume,
  muted,
  reloadKey,
  onReload,
  onVolume,
  onClose,
  onRemove,
  auth,
  onAuth,
}: {
  stream: StreamItem | null;
  settings: AppSettings;
  streamCount: number;
  volume: number;
  muted: boolean;
  reloadKey: number;
  onReload: () => void;
  onVolume: (stream: StreamItem, volume: number) => void;
  onClose: () => void;
  onRemove: (id: string) => void;
  auth: AuthState;
  onAuth: (auth: AuthState) => void;
}) {
  const chatRef = useRef<WebView>(null);
  const [commentText, setCommentText] = useState('');
  const [commentStatus, setCommentStatus] = useState('');
  const chat = stream ? chatURL(stream) : null;
  const {chromeVisible, showChrome} = useAutoHidingChrome(stream?.id ?? 'closed');
  const [webViewerCount, setWebViewerCount] = useState<number | null>(null);

  useEffect(() => {
    setCommentText('');
    setWebViewerCount(null);
  }, [stream?.id]);

  const sendComment = useCallback(() => {
    const text = commentText.trim();
    if (!text || !stream) {
      return;
    }
    setCommentStatus('送信中');
    postStreamComment(auth, stream, text)
      .then(nextAuth => {
        onAuth(nextAuth);
        setCommentText('');
        setCommentStatus('送信しました');
      })
      .catch(error => {
        if (!chatRef.current) {
          setCommentStatus(error instanceof Error ? error.message : String(error));
          return;
        }
        injectWebComment(chatRef.current, text);
        setCommentText('');
        setCommentStatus('Webチャットへ送信しました');
      });
  }, [auth, commentText, onAuth, stream]);

  const removeFocused = useCallback(() => {
    if (!stream) {
      return;
    }
    onRemove(stream.id);
    onClose();
  }, [onClose, onRemove, stream]);

  return (
    <Modal visible={!!stream} animationType="slide" onRequestClose={onClose}>
      <SafeAreaView style={styles.modal}>
        {stream && (
          <View style={styles.focusSurface}>
            <View style={styles.focusChatPanel}>
              {settings.showChat && chat ? (
                <WebView
                  ref={chatRef}
                  source={{uri: chat}}
                  userAgent={stream.platform === 'youtube' ? desktopUserAgent : mobileUserAgent}
                  javaScriptEnabled
                  domStorageEnabled
                  sharedCookiesEnabled
                  thirdPartyCookiesEnabled
                  setSupportMultipleWindows={false}
                  style={styles.focusChatWeb}
                />
              ) : (
                <View style={styles.focusUnavailable}>
                  <Text style={styles.focusUnavailableText}>このサービスはチャット入力未対応です</Text>
                </View>
              )}
            </View>
            <View style={styles.focusComposer}>
              <TextInput
                value={commentText}
                onChangeText={setCommentText}
                autoCapitalize="none"
                autoCorrect={false}
                placeholder="コメント"
                placeholderTextColor="rgba(255,255,255,0.55)"
                style={styles.focusInput}
                returnKeyType="send"
                onSubmitEditing={sendComment}
              />
              <TouchableOpacity style={styles.focusSend} onPress={sendComment}>
                <Text style={styles.focusSendText}>送信</Text>
              </TouchableOpacity>
              {!!commentStatus && <Text style={styles.focusStatus} numberOfLines={1}>{commentStatus}</Text>}
            </View>
            <View style={styles.focusPlayer} onTouchStart={showChrome}>
              <StreamPlayer
                stream={stream}
                settings={settings}
                streamCount={streamCount}
                paused={false}
                muted={muted || volume <= 0}
                volume={volume}
                reloadKey={reloadKey}
                onViewerCount={setWebViewerCount}
              />
              <View style={styles.playerChrome} pointerEvents="box-none">
                {!chromeVisible && <Pressable style={styles.chromeRevealTouch} onPress={showChrome} />}
                {settings.showViewerCount && <ViewerCountBadge stream={stream} externalCount={webViewerCount} visible={chromeVisible} />}
                <View
                  style={[styles.autoHideChrome, !chromeVisible && styles.autoHideChromeHidden]}
                  pointerEvents={chromeVisible ? 'box-none' : 'none'}>
                  <TouchableOpacity style={[styles.overlayButton, styles.focusCloseButton]} onPress={onClose}>
                    <Text style={styles.overlayIcon}>‹</Text>
                  </TouchableOpacity>
                  <TouchableOpacity style={[styles.overlayButton, styles.focusReloadButton]} onPress={onReload}>
                    <Text style={styles.overlayIcon}>↻</Text>
                  </TouchableOpacity>
                  <TouchableOpacity style={[styles.overlayButton, styles.focusRemoveButton]} onPress={removeFocused}>
                    <Text style={styles.overlayIcon}>×</Text>
                  </TouchableOpacity>
                  <VolumeOverlay
                    stream={stream}
                    volume={volume}
                    color={platformInfo(stream.platform).color}
                    onVolume={onVolume}
                    onInteract={showChrome}
                    mode="focus"
                  />
                </View>
              </View>
            </View>
          </View>
        )}
      </SafeAreaView>
    </Modal>
  );
}

function escapeForInjectedString(value: string) {
  return value
    .replace(/\\/g, '\\\\')
    .replace(/'/g, "\\'")
    .replace(/\r?\n/g, ' ');
}

function injectWebComment(webView: WebView | null, text: string) {
  if (!webView) {
    return;
  }
  const escaped = escapeForInjectedString(text);
  webView.injectJavaScript(`
    (function(){
      var text = '${escaped}';
      var inputSelectors = [
        'textarea[name=comment]',
        'textarea',
        'input[type=text]',
        '[contenteditable=true]',
        '#input #input',
        'yt-live-chat-text-input-field-renderer #input',
        '[data-testid*=chat][contenteditable=true]',
        '[data-testid*=message][contenteditable=true]',
        '.ProseMirror'
      ];
      var input = null;
      for (var i = 0; i < inputSelectors.length && !input; i++) {
        input = document.querySelector(inputSelectors[i]);
      }
      if (!input) return false;
      input.focus();
      if ('value' in input) {
        input.value = text;
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
      } else {
        input.textContent = text;
        try {
          input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
        } catch (e) {
          input.dispatchEvent(new Event('input', { bubbles: true }));
        }
      }
      var buttonSelectors = [
        'yt-live-chat-message-input-renderer #send-button button',
        '#send-button button',
        'button[aria-label*=Send]',
        'button[aria-label*=送信]',
        'button[type=submit]',
        '[role=button][aria-label*=Send]',
        '[role=button][aria-label*=送信]',
        '[data-testid*=send]',
        '[data-testid*=Send]',
        '.comment-post button',
        '.CommentPost button'
      ];
      var send = null;
      for (var j = 0; j < buttonSelectors.length && !send; j++) {
        send = document.querySelector(buttonSelectors[j]);
      }
      if (send) {
        send.click();
      } else {
        input.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', bubbles: true, cancelable: true}));
        input.dispatchEvent(new KeyboardEvent('keyup', {key: 'Enter', code: 'Enter', bubbles: true, cancelable: true}));
      }
      return true;
    })();
    true;
  `);
}

function SettingsScreen({
  streams,
  settings,
  onSettings,
  onImport,
  onMovePlatform,
  onClear,
  auth,
  onAuth,
  onLogin,
  onNiconicoLogin,
}: {
  streams: StreamItem[];
  settings: AppSettings;
  onSettings: (patch: Partial<AppSettings>) => void;
  onImport: (streams: StreamItem[], settings: Partial<AppSettings>) => void;
  onMovePlatform: (index: number, delta: number) => void;
  onClear: () => void;
  auth: AuthState;
  onAuth: (auth: AuthState) => void;
  onLogin: (service: OAuthService) => void;
  onNiconicoLogin: () => void;
}) {
  const [handoff, setHandoff] = useState('');
  const order = orderedPlatforms(settings.platformOrder);
  const compactCode = useMemo(() => compactHandoffCode(streams, settings.layoutMode), [settings.layoutMode, streams]);
  const exportText = useMemo(
    () =>
      JSON.stringify(
        {
          version: 2,
          streams,
          settings,
          compactCode,
          url: handoffURL(streams, settings.layoutMode),
        },
        null,
        2,
      ),
    [compactCode, settings, streams],
  );

  const importPayload = () => {
    try {
      const decoded = decodeHandoff(handoff);
      const nextStreams = decoded.streams.map(stream => makeStream(stream.platform, stream.channel));
      onImport(nextStreams, decoded.settings);
      setHandoff('');
    } catch {
      Alert.alert('読み込み失敗', 'JSON、iOS引き継ぎコード、multiview:// URL のいずれかを貼り付けてください。');
    }
  };

  return (
    <ScrollView style={styles.settings} contentContainerStyle={styles.settingsContent}>
      <Text style={styles.sectionTitle}>再生</Text>
      <SettingSwitch title="音声を有効にして開始" value={settings.playAudio} onValueChange={value => onSettings({playAudio: value})} />
      <SettingSwitch title="拡大時にチャットを表示" value={settings.showChat} onValueChange={value => onSettings({showChat: value})} />
      <SettingSwitch title="同接数を左下に表示" value={settings.showViewerCount} onValueChange={value => onSettings({showViewerCount: value})} />
      <SettingSwitch title="レイド先を自動追加" value={settings.autoFollowRaids} onValueChange={value => onSettings({autoFollowRaids: value})} />
      <SettingSwitch title="YouTubeをiframe優先で再生" value={settings.youtubePreferIframe} onValueChange={value => onSettings({youtubePreferIframe: value})} />
      <SettingSwitch title="YouTubeライブを安定バッファで再生" value={settings.youtubeStableBuffer} onValueChange={value => onSettings({youtubeStableBuffer: value})} />

      <Text style={styles.sectionTitle}>表示</Text>
      <LayoutModeSettingRow value={settings.layoutMode} onChange={value => onSettings({layoutMode: value})} />

      <Text style={styles.sectionTitle}>画質</Text>
      <QualityRow title="Wi-Fi時の画質" value={settings.wifiQuality} onChange={value => onSettings({wifiQuality: value})} />
      <QualityRow title="モバイル通信時の画質" value={settings.mobileQuality} onChange={value => onSettings({mobileQuality: value})} />
      <SettingSwitch
        title="3本以上で自動エコノミー画質"
        value={settings.autoEconomyOnManyStreams}
        onValueChange={value => onSettings({autoEconomyOnManyStreams: value})}
      />
      <SettingSwitch
        title="ニコ生 低遅延"
        value={settings.niconicoLowLatency}
        onValueChange={value => onSettings({niconicoLowLatency: value})}
      />

      <Text style={styles.sectionTitle}>弾幕・通知</Text>
      <SettingSwitch title="弾幕を表示" value={settings.showDanmaku} onValueChange={value => onSettings({showDanmaku: value})} />
      <SettingSwitch title="スタンプ/絵文字を弾幕に表示" value={settings.showEmotes} onValueChange={value => onSettings({showEmotes: value})} />
      <NumberSettingRow
        title="文字サイズ"
        value={settings.danmakuFontSize}
        min={12}
        max={40}
        step={1}
        onChange={value => onSettings({danmakuFontSize: Math.round(value)})}
      />
      <NumberSettingRow
        title="速度"
        value={Math.round((settings.danmakuSpeed / 0.13) * 100)}
        min={20}
        max={300}
        step={10}
        formatValue={value => `${Math.round(value)}%`}
        onChange={value => onSettings({danmakuSpeed: (Math.round(value) / 100) * 0.13})}
      />
      <NumberSettingRow
        title="透過度"
        value={Math.round(settings.danmakuOpacity * 100)}
        min={30}
        max={100}
        step={5}
        formatValue={value => `${Math.round(value)}%`}
        onChange={value => onSettings({danmakuOpacity: Math.round(value) / 100})}
      />
      <NumberSettingRow
        title="最大行数"
        value={settings.danmakuMaxLines}
        min={0}
        max={20}
        step={1}
        formatValue={value => (value === 0 ? '自動' : String(Math.round(value)))}
        onChange={value => onSettings({danmakuMaxLines: Math.round(value)})}
      />
      <NumberSettingRow
        title="最大文字数"
        value={settings.danmakuMaxLength}
        min={0}
        max={500}
        step={25}
        formatValue={value => (value === 0 ? '無制限' : String(Math.round(value)))}
        onChange={value => onSettings({danmakuMaxLength: Math.round(value)})}
      />
      <SettingSwitch title="ギフト演出を表示" value={settings.showGiftEffects} onValueChange={value => onSettings({showGiftEffects: value, niconicoShowGift: value})} />
      <SettingSwitch title="ギフト通知音" value={settings.giftSoundEnabled} onValueChange={value => onSettings({giftSoundEnabled: value})} />
      <SettingSwitch title="ニコ生 ニコニ広告を表示" value={settings.niconicoShowNicoad} onValueChange={value => onSettings({niconicoShowNicoad: value})} />
      <SettingSwitch title="ニコ生 お知らせ通知を表示" value={settings.niconicoShowNotification} onValueChange={value => onSettings({niconicoShowNotification: value})} />

      <Text style={styles.sectionTitle}>サービス順</Text>
      {order.map((platform, index) => {
        const item = platformInfo(platform);
        return (
          <View key={platform} style={styles.orderRow}>
            <View style={[styles.platformDot, {backgroundColor: item.color}]} />
            <Text style={styles.orderLabel}>{item.label}</Text>
            <TouchableOpacity disabled={index === 0} style={[styles.smallButton, index === 0 && styles.disabled]} onPress={() => onMovePlatform(index, -1)}>
              <Text style={styles.smallButtonText}>上へ</Text>
            </TouchableOpacity>
            <TouchableOpacity disabled={index === order.length - 1} style={[styles.smallButton, index === order.length - 1 && styles.disabled]} onPress={() => onMovePlatform(index, 1)}>
              <Text style={styles.smallButtonText}>下へ</Text>
            </TouchableOpacity>
          </View>
        );
      })}

      <Text style={styles.sectionTitle}>Web</Text>
      <SettingSwitch title="Web広告ブロック" value={settings.blockWebAds} onValueChange={value => onSettings({blockWebAds: value})} />

      <Text style={styles.sectionTitle}>認証・コメント送信</Text>
      <AuthServicePanel service="kick" auth={auth} onAuth={onAuth} onLogin={onLogin} />
      <AuthServicePanel service="twitch" auth={auth} onAuth={onAuth} onLogin={onLogin} />
      <AuthServicePanel service="twitcasting" auth={auth} onAuth={onAuth} onLogin={onLogin} />
      <AuthServicePanel service="youtube" auth={auth} onAuth={onAuth} onLogin={onLogin} />
      <NiconicoLoginPanel onLogin={onNiconicoLogin} />

      <Text style={styles.sectionTitle}>引き継ぎ</Text>
      <Text style={styles.settingNote}>iOS互換の短いコードとURLも含めて出力します。</Text>
      <TextInput value={exportText} editable={false} multiline style={[styles.textArea, styles.readOnly]} />
      <TextInput
        value={handoff}
        onChangeText={setHandoff}
        multiline
        placeholder="ここに引き継ぎJSON / コード / URLを貼り付け"
        placeholderTextColor="#7d8794"
        style={styles.textArea}
      />
      <TouchableOpacity style={styles.fullButton} onPress={importPayload}>
        <Text style={styles.fullButtonText}>引き継ぎデータを読み込む</Text>
      </TouchableOpacity>
      <TouchableOpacity
        style={styles.clearButton}
        onPress={() => {
          Alert.alert('配信リストを削除', '保存済みの配信リストを空にします。', [
            {text: 'キャンセル', style: 'cancel'},
            {text: '削除', style: 'destructive', onPress: onClear},
          ]);
        }}>
        <Text style={styles.clearButtonText}>配信リストを空にする</Text>
      </TouchableOpacity>
    </ScrollView>
  );
}

function SettingSwitch({title, value, onValueChange}: {title: string; value: boolean; onValueChange: (value: boolean) => void}) {
  return (
    <View style={styles.settingRow}>
      <Text style={styles.settingTitle}>{title}</Text>
      <Switch value={value} onValueChange={onValueChange} />
    </View>
  );
}

function LayoutModeSettingRow({value, onChange}: {value: AppSettings['layoutMode']; onChange: (value: AppSettings['layoutMode']) => void}) {
  return (
    <View style={styles.settingRow}>
      <Text style={styles.settingTitle}>表示レイアウト</Text>
      <View style={styles.iconSegment}>
        <TouchableOpacity
          style={[styles.iconSegmentButton, value === 'stacked' && styles.iconSegmentButtonActive]}
          onPress={() => onChange('stacked')}>
          <Text style={[styles.iconSegmentText, value === 'stacked' && styles.iconSegmentTextActive]}>▥</Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.iconSegmentButton, value === 'grid' && styles.iconSegmentButtonActive]}
          onPress={() => onChange('grid')}>
          <Text style={[styles.iconSegmentText, value === 'grid' && styles.iconSegmentTextActive]}>▦</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

function NumberSettingRow({
  title,
  value,
  min,
  max,
  step,
  onChange,
  formatValue = numericValue => String(Math.round(numericValue)),
}: {
  title: string;
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (value: number) => void;
  formatValue?: (value: number) => string;
}) {
  const setValue = (next: number) => onChange(Math.min(max, Math.max(min, next)));
  return (
    <View style={styles.settingRow}>
      <Text style={styles.settingTitle}>{title}</Text>
      <View style={styles.stepper}>
        <TouchableOpacity style={styles.stepperButton} onPress={() => setValue(value - step)}>
          <Text style={styles.stepperButtonText}>−</Text>
        </TouchableOpacity>
        <Text style={styles.stepperValue}>{formatValue(value)}</Text>
        <TouchableOpacity style={styles.stepperButton} onPress={() => setValue(value + step)}>
          <Text style={styles.stepperButtonText}>＋</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

function AuthServicePanel({
  service,
  auth,
  onAuth,
  onLogin,
}: {
  service: OAuthService;
  auth: AuthState;
  onAuth: (auth: AuthState) => void;
  onLogin: (service: OAuthService) => void;
}) {
  const state = auth[service];
  const label = serviceLabel(service);
  const setConfig = (patch: Partial<typeof state.config>) => onAuth(updateAuthConfig(auth, service, patch));
  const logout = () => onAuth(signOut(auth, service));
  const redirectHelp = service === 'youtube'
    ? 'YouTubeはbot判定を避けるため埋め込みWebViewではなく外部ブラウザのDevice Code認証を使います。Client IDはDevice/TVまたはInstalled app向けを使ってください。'
    : 'Redirect URIは開発者ポータルに登録した値と完全一致させてください。';
  return (
    <View style={styles.authPanel}>
      <View style={styles.authHeader}>
        <View>
          <Text style={styles.authTitle}>{label}</Text>
          <Text style={styles.authStatus}>{authStatus(auth, service)}</Text>
        </View>
        <TouchableOpacity
          style={[styles.smallButton, state.token && styles.dangerButton]}
          onPress={() => (state.token ? logout() : onLogin(service))}>
          <Text style={styles.smallButtonText}>{state.token ? 'ログアウト' : 'ログイン'}</Text>
        </TouchableOpacity>
      </View>
      <TextInput
        value={state.config.clientId}
        onChangeText={value => setConfig({clientId: value})}
        autoCapitalize="none"
        autoCorrect={false}
        placeholder={`${label} Client ID`}
        placeholderTextColor="#7d8794"
        style={styles.authInput}
      />
      {service === 'kick' && (
        <TextInput
          value={state.config.clientSecret ?? ''}
          onChangeText={value => setConfig({clientSecret: value})}
          autoCapitalize="none"
          autoCorrect={false}
          secureTextEntry
          placeholder="Kick Client Secret (任意)"
          placeholderTextColor="#7d8794"
          style={styles.authInput}
        />
      )}
      {service !== 'youtube' && (
        <TextInput
          value={state.config.redirectURI}
          onChangeText={value => setConfig({redirectURI: value})}
          autoCapitalize="none"
          autoCorrect={false}
          placeholder="Redirect URI"
          placeholderTextColor="#7d8794"
          style={styles.authInput}
        />
      )}
      <Text style={styles.settingNote}>{redirectHelp}</Text>
    </View>
  );
}

function NiconicoLoginPanel({onLogin}: {onLogin: () => void}) {
  return (
    <View style={styles.authPanel}>
      <View style={styles.authHeader}>
        <View>
          <Text style={styles.authTitle}>ニコ生</Text>
          <Text style={styles.authStatus}>WebログインCookieを利用</Text>
        </View>
        <TouchableOpacity style={styles.smallButton} onPress={onLogin}>
          <Text style={styles.smallButtonText}>ログイン</Text>
        </TouchableOpacity>
      </View>
      <Text style={styles.settingNote}>
        ニコ生は公開OAuthがないため、iOSと同じくアプリ内WebViewでログインしてCookieをプレイヤーとコメント送信に共有します。
      </Text>
    </View>
  );
}

function NiconicoLoginModal({visible, onClose}: {visible: boolean; onClose: () => void}) {
  return (
    <Modal visible={visible} animationType="slide" onRequestClose={onClose}>
      <SafeAreaView style={styles.modal}>
        <View style={styles.loginHeader}>
          <Text style={styles.loginTitle}>ニコ生ログイン</Text>
          <TouchableOpacity style={styles.smallButton} onPress={onClose}>
            <Text style={styles.smallButtonText}>完了</Text>
          </TouchableOpacity>
        </View>
        <WebView
          source={{uri: 'https://account.nicovideo.jp/login?site=niconico&next_url=%2F'}}
          userAgent={mobileUserAgent}
          javaScriptEnabled
          domStorageEnabled
          sharedCookiesEnabled
          thirdPartyCookiesEnabled
          setSupportMultipleWindows={false}
          style={styles.loginWeb}
        />
      </SafeAreaView>
    </Modal>
  );
}

function QualityRow({
  title,
  value,
  onChange,
}: {
  title: string;
  value: 'high' | 'economy';
  onChange: (value: 'high' | 'economy') => void;
}) {
  return (
    <View style={styles.settingRow}>
      <Text style={styles.settingTitle}>{title}</Text>
      <View style={styles.segment}>
        <Pill active={value === 'high'} label="高画質" onPress={() => onChange('high')} />
        <Pill active={value === 'economy'} label="エコノミー" onPress={() => onChange('economy')} />
      </View>
    </View>
  );
}

const sourceBridgeScript = `
(function(){
  if (window.__multiViewURLBridge) true;
  window.__multiViewURLBridge = true;
  var last = '';
  var lastGestureAt = 0;
  function recentGesture(){ return Date.now() - lastGestureAt < 1600; }
  function post(url){
    try {
      var value = String(url || location.href || '');
      if (!value || value === last) return;
      last = value;
      window.ReactNativeWebView.postMessage(JSON.stringify({type:'streamURL', url:value}));
    } catch(e) {}
  }
  function postSoon(url){
    setTimeout(function(){ post(url); post(location.href); }, 80);
    setTimeout(function(){ post(location.href); }, 500);
  }
  ['pointerdown','touchstart','mousedown'].forEach(function(name){
    document.addEventListener(name, function(){ lastGestureAt = Date.now(); }, true);
  });
  document.addEventListener('click', function(event){
    lastGestureAt = Date.now();
    var node = event.target;
    while (node && node !== document && !(node.tagName && node.tagName.toLowerCase() === 'a')) node = node.parentNode;
    if (node && node.href) postSoon(node.href);
  }, true);
  ['pushState','replaceState'].forEach(function(name){
    var original = history[name];
    history[name] = function(){
      var result = original.apply(this, arguments);
      if (recentGesture()) postSoon(location.href);
      return result;
    };
  });
  window.addEventListener('popstate', function(){ if (recentGesture()) postSoon(location.href); });
  true;
})();
`;

function webFallbackScript(blockAds: boolean, platform: PlatformId) {
  // iOS パリティの広告/ポップアップ対策をまず注入する:
  //  - blockAds 時: 広告ドメインの iframe/script を DOM から剥がす
  //  - ニコ生: 快適視聴/プレミアム会員モーダルを隠す
  //  - Kick/Twitch: 埋め込みプレイヤーの tap を止める
  return `
  ${blockAds ? adNetworkBlockerScript : ''}
  ${platformAdBlockExtras(platform)}
  (function(){
    function toViewerNumber(value){
      if (value == null) return null;
      var parsed = Number(String(value).replace(/[^0-9]/g, ''));
      return isFinite(parsed) && parsed >= 0 ? Math.round(parsed) : null;
    }
    function toPlainViewerNumber(value){
      if (value == null) return null;
      if (!/^\\s*[0-9][0-9,\\s\\u00a0]*\\s*$/.test(String(value))) return null;
      return toViewerNumber(value);
    }
    function parseJSONLike(value){
      try {
        if (typeof value === 'string') return JSON.parse(value);
        return value || null;
      } catch(e) {
        return null;
      }
    }
    function getYouTubeInitialData(){
      return parseJSONLike(window.ytInitialData);
    }
    function getYouTubeInitialPlayer(){
      return parseJSONLike(window.ytInitialPlayerResponse);
    }
    function isYouTubeLivePage(data){
      try {
        var player = getYouTubeInitialPlayer();
        var details = player && player.videoDetails;
        var liveDetails = player && player.microformat &&
          player.microformat.playerMicroformatRenderer &&
          player.microformat.playerMicroformatRenderer.liveBroadcastDetails;
        var liveIndicator = data && data.playerOverlays &&
          data.playerOverlays.playerOverlayRenderer &&
          data.playerOverlays.playerOverlayRenderer.liveIndicatorText;
        return Boolean(
          (details && (details.isLive === true || details.isLiveContent === true)) ||
          (liveDetails && liveDetails.isLiveNow === true) ||
          liveIndicator
        );
      } catch(e) {
        return false;
      }
    }
    function desktopViewerCountFromInitialData(data){
      try {
        var contents = data && data.contents && data.contents.twoColumnWatchNextResults &&
          data.contents.twoColumnWatchNextResults.results &&
          data.contents.twoColumnWatchNextResults.results.results &&
          data.contents.twoColumnWatchNextResults.results.results.contents;
        if (!Array.isArray(contents)) return null;
        for (var i = 0; i < contents.length; i += 1) {
          var renderer = contents[i] && contents[i].videoPrimaryInfoRenderer &&
            contents[i].videoPrimaryInfoRenderer.viewCount &&
            contents[i].videoPrimaryInfoRenderer.viewCount.videoViewCountRenderer;
          if (renderer && renderer.isLive === true) {
            var count = toViewerNumber(renderer.originalViewCount);
            if (count != null) return count;
          }
        }
      } catch(e) {}
      return null;
    }
    function mobileViewerCountFromInitialData(data){
      try {
        if (!isYouTubeLivePage(data)) return null;
        var contents = data && data.contents && data.contents.singleColumnWatchNextResults &&
          data.contents.singleColumnWatchNextResults.results &&
          data.contents.singleColumnWatchNextResults.results.results &&
          data.contents.singleColumnWatchNextResults.results.results.contents;
        if (!Array.isArray(contents)) return null;
        for (var i = 0; i < contents.length; i += 1) {
          var section = contents[i] && contents[i].slimVideoMetadataSectionRenderer;
          var sectionContents = section && section.contents;
          if (!Array.isArray(sectionContents)) continue;
          for (var j = 0; j < sectionContents.length; j += 1) {
            var info = sectionContents[j] && sectionContents[j].slimVideoInformationRenderer;
            var subtitles = [info && info.collapsedSubtitle, info && info.expandedSubtitle];
            for (var k = 0; k < subtitles.length; k += 1) {
              var runs = subtitles[k] && subtitles[k].runs;
              if (Array.isArray(runs) && runs.length > 1) {
                var count = toPlainViewerNumber(runs[0] && runs[0].text);
                if (count != null) return count;
              }
            }
          }
        }
      } catch(e) {}
      return null;
    }
    function youtubeViewerCountFromInitialData(){
      var data = getYouTubeInitialData();
      var desktopCount = desktopViewerCountFromInitialData(data);
      if (desktopCount != null) return desktopCount;
      return mobileViewerCountFromInitialData(data);
    }
    function postYouTubeViewerCount(){
      try {
        var count = youtubeViewerCountFromInitialData();
        if (count != null && window.ReactNativeWebView) {
          window.ReactNativeWebView.postMessage(JSON.stringify({type:'viewerCount', count:count}));
        }
      } catch(e) {}
    }
    function tame(){
      try {
        document.querySelectorAll('video,audio').forEach(function(media){
          media.setAttribute('playsinline','');
          media.setAttribute('webkit-playsinline','');
        });
      } catch(e) {}
      ${
        blockAds
          ? `
      try {
        var selectors = ['[class*=ad-]','[id*=ad-]','[class*=banner]','[id*=banner]','[class*=popup]','[class*=modal]'];
        selectors.forEach(function(sel){
          document.querySelectorAll(sel).forEach(function(node){
            var text = (node.innerText || node.textContent || '').slice(0, 120);
            if (/広告|Ad|Premium|プレミアム|popup/i.test(text) || /ad|banner|popup|modal/i.test(node.className || node.id || '')) {
              node.style.setProperty('display','none','important');
            }
          });
        });
      } catch(e) {}
      `
          : ''
      }
    }
    tame();
    postYouTubeViewerCount();
    new MutationObserver(function(){
      tame();
      postYouTubeViewerCount();
    }).observe(document.documentElement, {childList:true, subtree:true});
    setInterval(postYouTubeViewerCount, 5000);
    window.mvPlay=function(){
      document.querySelectorAll('video,audio').forEach(function(media){try{var p=media.play&&media.play();if(p&&p.catch)p.catch(function(){});}catch(e){}});
    };
    window.mvPause=function(){
      document.querySelectorAll('video,audio').forEach(function(media){try{media.pause();}catch(e){}});
    };
    window.mvSetVolume=function(v){
      var n=Math.max(0,Math.min(1,+v||0));
      document.querySelectorAll('video,audio').forEach(function(media){try{media.muted=n<=0;media.volume=n;}catch(e){}});
    };
    true;
  })();
  `;
}

const styles = StyleSheet.create({
  app: {
    flex: 1,
    backgroundColor: '#05070a',
    paddingTop: (StatusBar.currentHeight ?? 0) + 4,
  },
  content: {
    flex: 1,
  },
  tabBar: {
    minHeight: 58,
    paddingHorizontal: 8,
    paddingTop: 7,
    borderTopWidth: 1,
    borderTopColor: '#18202b',
    backgroundColor: '#090d12',
    flexDirection: 'row',
  },
  tabButton: {
    flex: 1,
    height: 42,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 7,
  },
  tabButtonActive: {
    backgroundColor: '#162231',
  },
  tabText: {
    color: '#8c98a8',
    fontSize: 13,
    fontWeight: '600',
  },
  tabTextActive: {
    color: '#f7f9fc',
  },
  screen: {
    flex: 1,
  },
  sourceTabs: {
    minHeight: 52,
    maxHeight: 52,
    borderTopWidth: 1,
    borderTopColor: '#18202b',
    backgroundColor: '#090d12',
  },
  sourceTabsContent: {
    paddingHorizontal: 10,
    paddingVertical: 8,
    alignItems: 'center',
  },
  pill: {
    height: 32,
    paddingHorizontal: 14,
    marginRight: 8,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: '#263241',
    backgroundColor: '#101720',
    alignItems: 'center',
    justifyContent: 'center',
  },
  pillActive: {
    backgroundColor: '#1b2633',
  },
  pillText: {
    color: '#9aa7b7',
    fontSize: 13,
    fontWeight: '700',
  },
  pillTextActive: {
    color: '#f7f9fc',
  },
  browserFrame: {
    flex: 1,
    backgroundColor: '#000',
  },
  viewBody: {
    flex: 1,
  },
  viewBottomControls: {
    minHeight: 56,
    paddingHorizontal: 10,
    paddingVertical: 8,
    borderTopWidth: 1,
    borderTopColor: '#18202b',
    backgroundColor: 'rgba(9,13,18,0.96)',
    flexDirection: 'row',
    alignItems: 'center',
  },
  iconSegment: {
    width: 96,
    height: 36,
    padding: 2,
    borderRadius: 8,
    backgroundColor: '#101720',
    borderWidth: 1,
    borderColor: '#263241',
    flexDirection: 'row',
  },
  iconSegmentButton: {
    flex: 1,
    borderRadius: 6,
    alignItems: 'center',
    justifyContent: 'center',
  },
  iconSegmentButtonActive: {
    backgroundColor: '#2f8cff',
  },
  iconSegmentText: {
    color: '#9aa7b7',
    fontSize: 18,
    fontWeight: '900',
    lineHeight: 22,
  },
  iconSegmentTextActive: {
    color: '#fff',
  },
  viewBottomSpacer: {
    flex: 1,
  },
  bottomIconButton: {
    width: 40,
    height: 36,
    borderRadius: 8,
    backgroundColor: '#1a2532',
    alignItems: 'center',
    justifyContent: 'center',
  },
  bottomIconText: {
    color: '#dce6f3',
    fontSize: 24,
    fontWeight: '800',
    lineHeight: 26,
  },
  viewToolbar: {
    minHeight: 44,
    paddingHorizontal: 14,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  toolbarActions: {
    flexDirection: 'row',
  },
  sectionTitle: {
    color: '#f7f9fc',
    fontSize: 18,
    fontWeight: '700',
    marginBottom: 10,
  },
  primaryButton: {
    height: 36,
    paddingHorizontal: 16,
    borderRadius: 7,
    backgroundColor: '#2f8cff',
    justifyContent: 'center',
  },
  primaryButtonText: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '700',
  },
  globalControls: {
    minHeight: 42,
    paddingHorizontal: 10,
    flexDirection: 'row',
    flexWrap: 'wrap',
  },
  controlButton: {
    height: 32,
    paddingHorizontal: 10,
    marginRight: 6,
    marginBottom: 6,
    borderRadius: 7,
    backgroundColor: '#182433',
    alignItems: 'center',
    justifyContent: 'center',
  },
  controlButtonActive: {
    backgroundColor: '#2b3444',
    borderWidth: 1,
    borderColor: '#67a8ff',
  },
  controlButtonText: {
    color: '#dce6f3',
    fontSize: 12,
    fontWeight: '800',
  },
  empty: {
    flex: 1,
    padding: 24,
    alignItems: 'center',
    justifyContent: 'center',
  },
  emptyTitle: {
    color: '#f7f9fc',
    fontSize: 20,
    fontWeight: '700',
    marginBottom: 8,
  },
  emptyText: {
    color: '#9aa7b7',
    fontSize: 14,
    lineHeight: 20,
    textAlign: 'center',
  },
  streamGrid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    padding: 8,
    paddingBottom: 18,
  },
  streamCellWrap: {
    padding: 6,
  },
  streamCell: {
    overflow: 'hidden',
    borderRadius: 18,
    borderWidth: 0.5,
    borderColor: 'rgba(255,255,255,0.18)',
    backgroundColor: '#000',
  },
  streamMeta: {
    height: 34,
    paddingHorizontal: 10,
    flexDirection: 'row',
    alignItems: 'center',
  },
  platformDot: {
    width: 9,
    height: 9,
    borderRadius: 5,
    marginRight: 8,
  },
  streamTitle: {
    flex: 1,
    color: '#e6edf7',
    fontSize: 13,
    fontWeight: '700',
  },
  player: {
    aspectRatio: 16 / 9,
    backgroundColor: '#000',
    position: 'relative',
  },
  nativePlayer: {
    flex: 1,
    backgroundColor: '#000',
  },
  webPlayer: {
    flex: 1,
    backgroundColor: '#000',
  },
  hiddenBridgeWeb: {
    position: 'absolute',
    left: -2,
    top: -2,
    width: 1,
    height: 1,
    opacity: 0,
  },
  playerChrome: {
    position: 'absolute',
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
  },
  autoHideChrome: {
    position: 'absolute',
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
    opacity: 1,
  },
  autoHideChromeHidden: {
    opacity: 0,
  },
  chromeRevealTouch: {
    position: 'absolute',
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
  },
  cellTopControls: {
    position: 'absolute',
    top: 8,
    right: 8,
    flexDirection: 'row',
  },
  overlayButton: {
    width: 32,
    height: 32,
    marginLeft: 8,
    borderRadius: 16,
    backgroundColor: 'rgba(0,0,0,0.38)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  overlayIcon: {
    color: '#fff',
    fontSize: 20,
    fontWeight: '800',
    lineHeight: 22,
  },
  playerPlaceholder: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#000',
  },
  playerStatus: {
    color: '#9aa7b7',
    marginTop: 8,
    paddingHorizontal: 12,
    textAlign: 'center',
    fontSize: 12,
  },
  playerBadge: {
    position: 'absolute',
    left: 8,
    bottom: 8,
    maxWidth: '88%',
    minHeight: 24,
    paddingHorizontal: 8,
    borderRadius: 7,
    backgroundColor: 'rgba(5, 7, 10, 0.76)',
    justifyContent: 'center',
  },
  playerBadgeWarning: {
    backgroundColor: 'rgba(58, 23, 32, 0.82)',
  },
  playerBadgeText: {
    color: '#dce6f3',
    fontSize: 11,
    fontWeight: '700',
  },
  volumeOverlay: {
    position: 'absolute',
    width: 42,
    borderRadius: 18,
    backgroundColor: 'rgba(0,0,0,0.42)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.14)',
    alignItems: 'center',
    paddingTop: 12,
    paddingBottom: 10,
  },
  cellVolumeOverlay: {
    left: 10,
    top: 8,
    height: '62%',
  },
  focusVolumeOverlay: {
    right: 10,
    top: '15%',
    height: '70%',
  },
  volumeTrack: {
    flex: 1,
    width: 4,
    marginBottom: 10,
    borderRadius: 2,
    backgroundColor: 'rgba(255,255,255,0.28)',
    overflow: 'visible',
    justifyContent: 'flex-end',
  },
  volumeLevel: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    width: 4,
    borderRadius: 2,
  },
  volumeThumb: {
    position: 'absolute',
    left: -5.5,
    width: 15,
    height: 15,
    borderRadius: 7.5,
    backgroundColor: '#fff',
    transform: [{translateY: 7.5}],
  },
  volumeIcon: {
    color: '#fff',
    fontSize: 13,
    fontWeight: '800',
    lineHeight: 18,
  },
  viewerBadge: {
    position: 'absolute',
    left: 10,
    bottom: 56,
    zIndex: 20,
    elevation: 20,
    minHeight: 28,
    paddingHorizontal: 8,
    borderRadius: 12,
    backgroundColor: 'rgba(0,0,0,0.62)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.12)',
    flexDirection: 'row',
    alignItems: 'center',
  },
  viewerBadgeIcon: {
    color: '#fff',
    fontSize: 12,
    marginRight: 5,
  },
  viewerBadgeText: {
    color: '#fff',
    fontSize: 12,
    fontWeight: '800',
  },
  reorderHandle: {
    position: 'absolute',
    right: 8,
    bottom: 8,
    width: 44,
    height: 32,
    borderRadius: 14,
    backgroundColor: 'rgba(0,0,0,0.46)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.2)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  reorderIcon: {
    color: '#fff',
    fontSize: 22,
    fontWeight: '800',
    lineHeight: 24,
  },
  commentBar: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    height: 46,
    paddingHorizontal: 10,
    backgroundColor: 'rgba(0,0,0,0.6)',
    flexDirection: 'row',
    alignItems: 'center',
  },
  commentInput: {
    flex: 1,
    height: 30,
    paddingHorizontal: 10,
    borderRadius: 8,
    backgroundColor: 'rgba(255,255,255,0.14)',
    color: '#fff',
    fontSize: 13,
  },
  commentSend: {
    width: 42,
    height: 30,
    marginLeft: 8,
    alignItems: 'center',
    justifyContent: 'center',
  },
  commentSendText: {
    color: '#67a8ff',
    fontSize: 13,
    fontWeight: '800',
  },
  commentStatus: {
    position: 'absolute',
    left: 10,
    right: 58,
    bottom: 42,
    minHeight: 20,
    paddingHorizontal: 7,
    borderRadius: 6,
    backgroundColor: 'rgba(0,0,0,0.72)',
    color: '#dce6f3',
    fontSize: 10,
    fontWeight: '700',
  },
  smallButton: {
    minWidth: 54,
    height: 30,
    paddingHorizontal: 10,
    marginRight: 6,
    marginBottom: 4,
    borderRadius: 7,
    backgroundColor: '#1a2532',
    alignItems: 'center',
    justifyContent: 'center',
  },
  smallButtonText: {
    color: '#dce6f3',
    fontSize: 12,
    fontWeight: '700',
  },
  disabled: {
    opacity: 0.35,
  },
  dangerButton: {
    height: 30,
    paddingHorizontal: 10,
    borderRadius: 7,
    backgroundColor: '#3a1720',
    alignItems: 'center',
    justifyContent: 'center',
  },
  dangerButtonText: {
    color: '#ffb4c0',
    fontSize: 12,
    fontWeight: '700',
  },
  volumeRail: {
    height: 3,
    backgroundColor: '#101720',
  },
  volumeFill: {
    height: 3,
    backgroundColor: '#67a8ff',
  },
  modal: {
    flex: 1,
    backgroundColor: '#05070a',
  },
  modalHeader: {
    minHeight: 56,
    paddingHorizontal: 16,
    borderBottomWidth: 1,
    borderBottomColor: '#18202b',
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  modalTitle: {
    color: '#f7f9fc',
    fontSize: 18,
    fontWeight: '700',
    flexShrink: 1,
  },
  closeText: {
    color: '#67a8ff',
    fontSize: 15,
    fontWeight: '700',
  },
  input: {
    height: 48,
    marginHorizontal: 16,
    marginTop: 16,
    paddingHorizontal: 12,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: '#263241',
    backgroundColor: '#101720',
    color: '#f7f9fc',
    fontSize: 16,
  },
  fullButton: {
    minHeight: 46,
    marginHorizontal: 16,
    marginTop: 14,
    paddingHorizontal: 14,
    borderRadius: 7,
    backgroundColor: '#2f8cff',
    alignItems: 'center',
    justifyContent: 'center',
  },
  fullButtonText: {
    color: '#fff',
    fontSize: 15,
    fontWeight: '800',
  },
  focusSurface: {
    flex: 1,
    paddingHorizontal: 10,
    paddingTop: 10,
    paddingBottom: 10,
    backgroundColor: '#000',
  },
  focusChatPanel: {
    flex: 1,
    minHeight: 180,
    borderRadius: 18,
    overflow: 'hidden',
    backgroundColor: '#090d12',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.1)',
  },
  focusChatWeb: {
    flex: 1,
    backgroundColor: '#000',
  },
  focusUnavailable: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: 18,
  },
  focusUnavailableText: {
    color: '#9aa7b7',
    fontSize: 14,
    textAlign: 'center',
  },
  focusComposer: {
    height: 48,
    marginTop: 8,
    marginBottom: 8,
    flexDirection: 'row',
    alignItems: 'center',
  },
  focusStatus: {
    position: 'absolute',
    left: 12,
    right: 70,
    top: -22,
    color: '#dce6f3',
    fontSize: 11,
    fontWeight: '700',
  },
  focusInput: {
    flex: 1,
    height: 40,
    paddingHorizontal: 12,
    borderRadius: 14,
    backgroundColor: 'rgba(255,255,255,0.1)',
    color: '#fff',
    fontSize: 15,
  },
  focusSend: {
    width: 54,
    height: 40,
    marginLeft: 8,
    alignItems: 'center',
    justifyContent: 'center',
  },
  focusSendText: {
    color: '#67a8ff',
    fontSize: 14,
    fontWeight: '800',
  },
  focusPlayer: {
    width: '100%',
    aspectRatio: 16 / 9,
    backgroundColor: '#000',
    position: 'relative',
  },
  focusCloseButton: {
    position: 'absolute',
    top: 10,
    left: 10,
    width: 36,
    height: 36,
    borderRadius: 18,
    marginLeft: 0,
  },
  focusRemoveButton: {
    position: 'absolute',
    top: 10,
    right: 10,
    width: 36,
    height: 36,
    borderRadius: 18,
    marginLeft: 0,
  },
  focusReloadButton: {
    position: 'absolute',
    top: 10,
    right: 54,
    width: 36,
    height: 36,
    borderRadius: 18,
    marginLeft: 0,
  },
  settings: {
    flex: 1,
  },
  settingsContent: {
    padding: 16,
    paddingBottom: 24,
  },
  settingRow: {
    minHeight: 58,
    paddingVertical: 10,
    borderBottomWidth: 1,
    borderBottomColor: '#18202b',
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  settingTitle: {
    flex: 1,
    color: '#edf3fb',
    fontSize: 15,
    fontWeight: '700',
    marginRight: 14,
  },
  settingNote: {
    maxWidth: 320,
    color: '#8c98a8',
    fontSize: 12,
    lineHeight: 17,
  },
  authPanel: {
    paddingVertical: 12,
    borderBottomWidth: 1,
    borderBottomColor: '#18202b',
  },
  authHeader: {
    minHeight: 36,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  authTitle: {
    color: '#edf3fb',
    fontSize: 15,
    fontWeight: '800',
  },
  authStatus: {
    marginTop: 2,
    color: '#8c98a8',
    fontSize: 12,
    fontWeight: '700',
  },
  authInput: {
    minHeight: 42,
    marginTop: 8,
    paddingHorizontal: 10,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: '#263241',
    backgroundColor: '#101720',
    color: '#f7f9fc',
    fontSize: 13,
  },
  loginHeader: {
    minHeight: 52,
    paddingHorizontal: 14,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    borderBottomWidth: 1,
    borderBottomColor: '#18202b',
  },
  loginTitle: {
    color: '#edf3fb',
    fontSize: 17,
    fontWeight: '800',
  },
  loginWeb: {
    flex: 1,
    backgroundColor: '#05070a',
  },
  segment: {
    flexDirection: 'row',
  },
  stepper: {
    minWidth: 128,
    height: 36,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: '#263241',
    backgroundColor: '#101720',
    flexDirection: 'row',
    alignItems: 'center',
    overflow: 'hidden',
  },
  stepperButton: {
    width: 38,
    height: 36,
    alignItems: 'center',
    justifyContent: 'center',
  },
  stepperButtonText: {
    color: '#dce6f3',
    fontSize: 22,
    fontWeight: '800',
    lineHeight: 24,
  },
  stepperValue: {
    flex: 1,
    color: '#f7f9fc',
    fontSize: 13,
    fontWeight: '800',
    textAlign: 'center',
  },
  orderRow: {
    minHeight: 48,
    paddingVertical: 8,
    borderBottomWidth: 1,
    borderBottomColor: '#18202b',
    flexDirection: 'row',
    alignItems: 'center',
  },
  orderLabel: {
    flex: 1,
    color: '#edf3fb',
    fontSize: 15,
    fontWeight: '700',
  },
  textArea: {
    minHeight: 110,
    marginTop: 10,
    padding: 10,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: '#263241',
    backgroundColor: '#101720',
    color: '#f7f9fc',
    textAlignVertical: 'top',
    fontSize: 12,
  },
  readOnly: {
    color: '#a9b5c6',
  },
  clearButton: {
    minHeight: 44,
    marginHorizontal: 16,
    marginTop: 14,
    borderRadius: 7,
    backgroundColor: '#2a151b',
    alignItems: 'center',
    justifyContent: 'center',
  },
  clearButtonText: {
    color: '#ffb4c0',
    fontSize: 15,
    fontWeight: '800',
  },
});
