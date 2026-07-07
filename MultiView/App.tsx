import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {
  Alert,
  AppState,
  LayoutAnimation,
  Platform,
  ScrollView,
  PanResponder,
  Pressable,
  StatusBar,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  UIManager,
  View,
  Linking,
} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import AsyncStorage from '@react-native-async-storage/async-storage';
import {
  AUTH_STORAGE_KEY,
  PENDING_DEVICE_OAUTH_STORAGE_KEY,
  PENDING_OAUTH_STORAGE_KEY,
  completeOAuthRedirect,
  createOAuthURLSingleFlight,
  createOAuthStart,
  defaultAuthState,
  deviceOAuthErrorDisposition,
  isOAuthRedirectForPending,
  maintainAuthSessions,
  mergeAuthMaintenanceSnapshot,
  mergeAuthUpdateSnapshot,
  nextDeviceOAuthPollInterval,
  oauthCompletionErrorDisposition,
  openURL,
  pollTwitchDeviceToken,
  pollYouTubeDeviceToken,
  postStreamComment,
  requestTwitchDeviceCode,
  requestYouTubeDeviceCode,
  readStoredAuthWithRetry,
  writeStoredAuthWithRetry,
  sanitizeAuthState,
  sanitizePendingDeviceOAuth,
  sanitizePendingOAuth,
  serviceLabel,
  type AuthCommit,
  type AuthState,
  type OAuthService,
  type PendingDeviceOAuth,
  type PendingOAuth,
} from './src/auth';
import {decodeHandoff} from './src/handoff';
import {makeStream} from './src/playback';
import type {AppSettings, HandoffImporter, NiconicoCommentSender, PlatformId, Source, StreamItem, TabId} from './src/types';
import {setRaidHandler} from './src/raidFollow';
import {startPlaybackService, stopPlaybackService} from './src/playbackService';
import {parseStreamURL} from './src/streamURL';
import {appSafeAreaEdges} from './src/layout';
import {orderedPlatforms, platformIds, platformInfo} from './src/platforms';
import {useAutoHidingChrome} from './src/useAutoHidingChrome';
import {TabButton} from './src/components/TabButton';
import {VolumeOverlay} from './src/components/VolumeOverlay';
import {ViewerCountBadge} from './src/components/ViewerCountBadge';
import {sharedStyles} from './src/components/sharedStyles';
import {StreamPlayer} from './src/players/StreamPlayer';
import {SourceBrowser} from './src/screens/SourceBrowser';
import {HandoffModal} from './src/screens/HandoffModal';
import {AddStreamModal} from './src/screens/AddStreamModal';
import {FocusModal} from './src/screens/FocusModal';
import {NiconicoLoginModal, SettingsScreen} from './src/screens/SettingsScreen';

// Android の LayoutAnimation は既定で無効。並び替え時にセルがスライドする視覚
// フィードバック(iOSのUITableView並び替えに相当)へ必要で、RN公式ドキュメント通り
// モジュールスコープで一度だけ有効化する(新アーキテクチャでは存在しないため guard)。
if (Platform.OS === 'android' && UIManager.setLayoutAnimationEnabledExperimental) {
  UIManager.setLayoutAnimationEnabledExperimental(true);
}

const STREAMS_KEY = 'multiview.android.streams.v2';
const LEGACY_STREAMS_KEY = 'multiview.android.streams.v1';
const SETTINGS_KEY = 'multiview.android.settings.v2';
const LEGACY_SETTINGS_KEY = 'multiview.android.settings.v1';
const VOLUMES_KEY = 'multiview.android.volumes.v1';

const settingsSchemaVersion = 3;

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

function orderedSources(sources: Source[], settings: AppSettings) {
  const order = orderedPlatforms(settings.platformOrder);
  return order.flatMap(platform => sources.filter(source => source.platform === platform));
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

export default function App() {
  const [hydrated, setHydrated] = useState(false);
  const [activeTab, setActiveTab] = useState<TabId>('viewing');
  const [streams, setStreams] = useState<StreamItem[]>([]);
  const [settings, setSettings] = useState<AppSettings>(defaultSettings);
  const [volumes, setVolumes] = useState<Record<string, number>>({});
  const [auth, setAuth] = useState<AuthState>(defaultAuthState);
  const [pendingOAuth, setPendingOAuth] = useState<PendingOAuth | null>(null);
  const [pendingDeviceOAuth, setPendingDeviceOAuth] = useState<PendingDeviceOAuth | null>(null);
  const [niconicoLoginOpen, setNiconicoLoginOpen] = useState(false);
  const authRef = useRef(auth);
  const authWriteChainRef = useRef<Promise<void>>(Promise.resolve());
  const authStorageReadFailedRef = useRef(false);
  const pendingOAuthRef = useRef(pendingOAuth);
  const pendingHandoffURLRef = useRef<string | null>(null);
  const pendingOAuthURLRef = useRef<string | null>(null);
  const oauthURLSingleFlightRef = useRef(createOAuthURLSingleFlight());
  authRef.current = auth;
  pendingOAuthRef.current = pendingOAuth;

  const updateAuth = useCallback<AuthCommit>((next, base, overwriteConflicts = []) => {
    const sanitizedBase = sanitizeAuthState(base);
    const sanitizedNext = sanitizeAuthState(next);
    const operation = authWriteChainRef.current
      .catch(() => undefined)
      .then(async () => {
        let current = authRef.current;
        if (authStorageReadFailedRef.current) {
          const recovered = await readStoredAuthWithRetry(() => AsyncStorage.getItem(AUTH_STORAGE_KEY));
          if (!recovered.ok) {
            throw new Error('保存済みの認証情報を再読み込みできないため、上書きを中止しました。もう一度お試しください。');
          }
          authStorageReadFailedRef.current = false;
          if (recovered.value) {
            try {
              current = sanitizeAuthState(JSON.parse(recovered.value));
              authRef.current = current;
              setAuth(current);
            } catch {
              // Corrupt auth JSON cannot contain a usable session. Remove only
              // that entry, then allow the explicit new auth operation to save.
              await AsyncStorage.removeItem(AUTH_STORAGE_KEY).catch(() => undefined);
            }
          }
        }
        const merged = mergeAuthUpdateSnapshot(sanitizedBase, current, sanitizedNext, overwriteConflicts);
        if (merged === current) {
          return current;
        }
        // 永続化に成功してから UI/メモリへ公開する。書き込み失敗時は throw させ、
        // UI だけログイン/更新済みになって再起動で巻き戻る不整合(refresh token
        // ローテーション後のセッション喪失)を防ぐ。
        const serialized = JSON.stringify(merged);
        await writeStoredAuthWithRetry(() => AsyncStorage.setItem(AUTH_STORAGE_KEY, serialized));
        authRef.current = merged;
        setAuth(merged);
        return merged;
      });
    authWriteChainRef.current = operation.then(() => undefined);
    return operation;
  }, []);

  const updatePendingOAuth = useCallback((next: PendingOAuth | null) => {
    pendingOAuthRef.current = next;
    setPendingOAuth(next);
    return next
      ? AsyncStorage.setItem(PENDING_OAUTH_STORAGE_KEY, JSON.stringify(next))
      : AsyncStorage.removeItem(PENDING_OAUTH_STORAGE_KEY);
  }, []);

  const updatePendingDeviceOAuth = useCallback((next: PendingDeviceOAuth | null) => {
    setPendingDeviceOAuth(next);
    return next
      ? AsyncStorage.setItem(PENDING_DEVICE_OAUTH_STORAGE_KEY, JSON.stringify(next))
      : AsyncStorage.removeItem(PENDING_DEVICE_OAUTH_STORAGE_KEY);
  }, []);

  const applyHandoffURL = useCallback((url: string) => {
    const decoded = decodeHandoff(url);
    const nextStreams = decoded.streams.map(stream => makeStream(stream.platform, stream.channel));
    setStreams(nextStreams);
    setSettings(current => ({...current, ...decoded.settings}));
    setActiveTab('viewing');
  }, []);

  useEffect(() => {
    let mounted = true;
    const readItem = (key: string) => AsyncStorage.getItem(key).catch(() => null);
    const readCurrentOrLegacy = async (key: string, legacyKey: string) => {
      const current = await readItem(key);
      return current ?? readItem(legacyKey);
    };
    Promise.all([
      readCurrentOrLegacy(STREAMS_KEY, LEGACY_STREAMS_KEY),
      readCurrentOrLegacy(SETTINGS_KEY, LEGACY_SETTINGS_KEY),
      readItem(VOLUMES_KEY),
      readStoredAuthWithRetry(() => AsyncStorage.getItem(AUTH_STORAGE_KEY)),
      readItem(PENDING_OAUTH_STORAGE_KEY),
      readItem(PENDING_DEVICE_OAUTH_STORAGE_KEY),
    ])
      .then(([savedStreams, savedSettings, savedVolumes, savedAuthRead, savedPendingOAuth, savedPendingDeviceOAuth]) => {
        if (!mounted) {
          return;
        }
        let hadInvalidData = false;
        const restore = (raw: string | null, apply: (value: unknown) => void) => {
          if (!raw) {
            return;
          }
          try {
            apply(JSON.parse(raw));
          } catch {
            hadInvalidData = true;
          }
        };
        restore(savedStreams, parsed => {
          if (Array.isArray(parsed)) {
            setStreams(
              parsed
                .filter(stream => stream && typeof stream === 'object' && 'platform' in stream && 'channel' in stream)
                .map(stream => makeStream((stream as StreamItem).platform as PlatformId, String((stream as StreamItem).channel))),
            );
          }
        });
        restore(savedSettings, parsed => setSettings(sanitizeSettings(parsed)));
        restore(savedVolumes, parsed => {
          if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
            setVolumes(parsed as Record<string, number>);
          }
        });
        if (savedAuthRead.ok) {
          authStorageReadFailedRef.current = false;
          if (savedAuthRead.value) {
            try {
              const restoredAuth = sanitizeAuthState(JSON.parse(savedAuthRead.value));
              authRef.current = restoredAuth;
              setAuth(restoredAuth);
            } catch {
              hadInvalidData = true;
              AsyncStorage.removeItem(AUTH_STORAGE_KEY).catch(() => undefined);
            }
          }
        } else {
          authStorageReadFailedRef.current = true;
          Alert.alert(
            '認証情報の読み込み失敗',
            '認証情報は上書きせず保持しました。認証操作の前にも再読み込みします。',
          );
        }
        restore(savedPendingOAuth, parsed => {
          const restoredPending = sanitizePendingOAuth(parsed);
          pendingOAuthRef.current = restoredPending;
          setPendingOAuth(restoredPending);
        });
        restore(savedPendingDeviceOAuth, parsed => {
          const restoredDevice = sanitizePendingDeviceOAuth(parsed);
          setPendingDeviceOAuth(restoredDevice);
        });
        if (hadInvalidData) {
          Alert.alert('一部データの読み込み失敗', '破損した保存項目だけを初期化し、他の設定と認証情報は保持しました。');
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
    if (!hydrated) {
      return;
    }
    // 音量はドラッグ中に連続更新される。move毎にディスクへ書かず、落ち着いてから
    // 1回だけ永続化する(UI/プレイヤーへの反映はstate経由で即時のまま)。
    const timer = setTimeout(() => {
      AsyncStorage.setItem(VOLUMES_KEY, JSON.stringify(volumes)).catch(() => undefined);
    }, 400);
    return () => clearTimeout(timer);
  }, [hydrated, volumes]);

  useEffect(() => {
    if (!hydrated) {
      return;
    }
    let stopped = false;
    let running = false;
    const maintain = async () => {
      if (stopped || running) {
        return;
      }
      running = true;
      try {
        const base = authRef.current;
        await maintainAuthSessions(base, async nextSnapshot => {
          if (stopped) {
            return;
          }
          const current = authRef.current;
          const merged = mergeAuthMaintenanceSnapshot(base, current, nextSnapshot);
          if (merged !== current) {
            await updateAuth(merged, current);
          }
        });
      } catch {
        // Transient provider/network errors are retried on the next foreground/interval pass.
      } finally {
        running = false;
      }
    };
    maintain();
    const interval = setInterval(maintain, 15 * 60_000);
    const subscription = AppState.addEventListener('change', state => {
      if (state === 'active') {
        maintain();
      }
    });
    return () => {
      stopped = true;
      clearInterval(interval);
      subscription.remove();
    };
  }, [hydrated, updateAuth]);

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
      if (!url.startsWith('multiview://')) {
        return;
      }
      if (!hydrated) {
        pendingOAuthURLRef.current = url;
        return;
      }
      const pending = pendingOAuthRef.current;
      if (!pending || !isOAuthRedirectForPending(pending, url)) {
        return;
      }
      oauthURLSingleFlightRef.current.run(url, async () => {
        try {
          const base = authRef.current;
          const next = await completeOAuthRedirect(base, pending, url);
          await updateAuth(next, base, [pending.service]);
          await updatePendingOAuth(null);
          Alert.alert('ログイン完了', `${serviceLabel(pending.service)}にログインしました。`);
        } catch (error) {
          const terminal = oauthCompletionErrorDisposition(error) === 'terminal';
          if (terminal) {
            await updatePendingOAuth(null).catch(() => undefined);
          }
          Alert.alert(
            terminal ? 'ログイン失敗' : 'ログイン通信失敗',
            `${error instanceof Error ? error.message : String(error)}${terminal ? '' : '\n認証状態は保持しました。ブラウザの「アプリに戻る」をもう一度押してください。'}`,
          );
        }
      }).catch(() => undefined);
    };
    const sub = Linking.addEventListener('url', handleURL);
    if (hydrated) {
      if (pendingOAuthURLRef.current) {
        const url = pendingOAuthURLRef.current;
        pendingOAuthURLRef.current = null;
        handleURL({url});
      }
      Linking.getInitialURL().then(url => {
        if (url) {
          handleURL({url});
        }
      }).catch(() => undefined);
    }
    return () => sub.remove();
  }, [applyHandoffURL, hydrated, updateAuth, updatePendingOAuth]);

  useEffect(() => {
    if (!hydrated || !pendingDeviceOAuth) {
      return;
    }
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let pollIntervalSeconds = pendingDeviceOAuth.intervalSeconds;
    const schedulePoll = (delaySeconds: number) => {
      if (!cancelled) {
        timer = setTimeout(poll, delaySeconds * 1000);
      }
    };
    const poll = async () => {
      if (cancelled) {
        return;
      }
      if (Date.now() > pendingDeviceOAuth.expiresAt) {
        await updatePendingDeviceOAuth(null).catch(() => undefined);
        if (!cancelled) {
          Alert.alert(`${serviceLabel(pendingDeviceOAuth.service)}ログイン失敗`, '認証コードの期限が切れました。もう一度ログインしてください。');
        }
        return;
      }
      try {
        const base = authRef.current;
        const next = pendingDeviceOAuth.service === 'twitch'
          ? await pollTwitchDeviceToken(base, pendingDeviceOAuth)
          : await pollYouTubeDeviceToken(base, pendingDeviceOAuth);
        if (cancelled) {
          return;
        }
        if (next) {
          await updateAuth(next, base, [pendingDeviceOAuth.service]);
          await updatePendingDeviceOAuth(null);
          if (!cancelled) {
            Alert.alert('ログイン完了', `${serviceLabel(pendingDeviceOAuth.service)}にログインしました。`);
          }
          return;
        }
        schedulePoll(pollIntervalSeconds);
      } catch (error) {
        if (cancelled) {
          return;
        }
        const disposition = deviceOAuthErrorDisposition(error);
        if (disposition === 'terminal') {
          await updatePendingDeviceOAuth(null).catch(() => undefined);
          Alert.alert(`${serviceLabel(pendingDeviceOAuth.service)}ログイン失敗`, error instanceof Error ? error.message : String(error));
          return;
        }
        pollIntervalSeconds = nextDeviceOAuthPollInterval(pollIntervalSeconds, disposition);
        const persisted = {...pendingDeviceOAuth, intervalSeconds: pollIntervalSeconds};
        await AsyncStorage.setItem(PENDING_DEVICE_OAUTH_STORAGE_KEY, JSON.stringify(persisted)).catch(() => undefined);
        schedulePoll(pollIntervalSeconds);
      }
    };
    timer = setTimeout(poll, 0);
    return () => {
      cancelled = true;
      if (timer) {
        clearTimeout(timer);
      }
    };
  }, [hydrated, pendingDeviceOAuth, updateAuth, updatePendingDeviceOAuth]);

  const startOAuthLogin = useCallback(async (service: OAuthService) => {
    try {
      if (service === 'youtube' || service === 'twitch') {
        const code = service === 'twitch'
          ? await requestTwitchDeviceCode(authRef.current)
          : await requestYouTubeDeviceCode(authRef.current);
        const device: PendingDeviceOAuth = {...code, service};
        await updatePendingDeviceOAuth(device);
        Alert.alert(
          `${serviceLabel(service)}ログイン`,
          `外部ブラウザで ${device.verificationUrl} を開き、コード ${device.userCode} を入力してください。完了まで自動で待機します。`,
        );
        openURL(device.verificationUrl).catch(() => undefined);
        return;
      }
      const start = await createOAuthStart(authRef.current, service);
      await updatePendingOAuth(start.pending);
      await openURL(start.url);
    } catch (error) {
      Alert.alert('ログイン開始失敗', error instanceof Error ? error.message : String(error));
    }
  }, [updatePendingDeviceOAuth, updatePendingOAuth]);

  const resumeDeviceOAuth = useCallback((pending: PendingDeviceOAuth) => {
    openURL(pending.verificationUrl).catch(error => {
      Alert.alert('ブラウザ起動失敗', error instanceof Error ? error.message : String(error));
    });
  }, []);

  const cancelDeviceOAuth = useCallback(() => {
    updatePendingDeviceOAuth(null).catch(error => {
      Alert.alert('認証キャンセル失敗', error instanceof Error ? error.message : String(error));
    });
  }, [updatePendingDeviceOAuth]);

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

  // 背景音声: 配信が1本以上 & 音声ON の間だけ前面サービスを起動しておく。
  // 視聴タブは非表示でもマウントしたままにするため、他タブ移動中もサービスと実再生が一致する。
  useEffect(() => {
    if (!hydrated) {
      return;
    }
    const playbackDesired = streams.length > 0 && settings.playAudio;
    if (playbackDesired) {
      startPlaybackService();
    } else {
      stopPlaybackService();
    }
    const subscription = AppState.addEventListener('change', state => {
      if (state === 'active' && playbackDesired) {
        startPlaybackService();
      }
    });
    return () => subscription.remove();
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

  const importHandoff = useCallback<HandoffImporter>((nextStreams, nextSettings, mode) => {
    if (mode === 'append') {
      // iOS Handoff「追加する」: 既存タブを保ち、未追加のものだけ足す。
      // レイアウト等の設定は「置き換える」時のみ反映する(iOS準拠)。
      setStreams(current => {
        const existing = new Set(current.map(stream => stream.id));
        return [...current, ...nextStreams.filter(stream => !existing.has(stream.id))];
      });
    } else {
      setStreams(nextStreams);
      setSettings(current => sanitizeSettings({...current, ...nextSettings}));
    }
    setActiveTab('viewing');
  }, []);

  const setStreamVolume = useCallback((stream: StreamItem, volume: number) => {
    setVolumes(current => ({...current, [stream.id]: Math.max(0, Math.min(1, volume))}));
  }, []);

  return (
    <SafeAreaView style={styles.app} edges={appSafeAreaEdges}>
      <StatusBar barStyle="light-content" backgroundColor="#05070a" translucent={false} />
      <View style={styles.content}>
        {activeTab === 'following' && (
          <SourceBrowser sources={orderedSources(followingSources, settings)} blockWebAds={settings.blockWebAds} onAdd={addStream} />
        )}
        {activeTab === 'ranking' && (
          <SourceBrowser sources={orderedSources(rankingSources, settings)} blockWebAds={settings.blockWebAds} onAdd={addStream} />
        )}
        <View
          style={[styles.tabPanel, activeTab !== 'viewing' && styles.hiddenViewingPanel]}
          pointerEvents={activeTab === 'viewing' ? 'auto' : 'none'}>
          <ViewingScreen
            active={activeTab === 'viewing'}
            streams={streams}
            settings={settings}
            volumes={volumes}
            onAdd={addStream}
            onRemove={removeStream}
            onMove={moveStreamTo}
            onVolume={setStreamVolume}
            onSettings={updateSettings}
            onImport={importHandoff}
            auth={auth}
            onAuth={updateAuth}
          />
        </View>
        {activeTab === 'settings' && (
          <SettingsScreen
            settings={settings}
            onSettings={updateSettings}
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
            pendingDeviceOAuth={pendingDeviceOAuth}
            onResumeDeviceOAuth={resumeDeviceOAuth}
            onCancelDeviceOAuth={cancelDeviceOAuth}
            onNiconicoLogin={() => setNiconicoLoginOpen(true)}
          />
        )}
      </View>
      <NiconicoLoginModal visible={niconicoLoginOpen} onClose={() => setNiconicoLoginOpen(false)} />

      <View style={styles.tabBar}>
        <TabButton active={activeTab === 'following'} icon="◉" label="フォロー" onPress={() => setActiveTab('following')} />
        <TabButton active={activeTab === 'ranking'} icon="▤" label="ランキング" onPress={() => setActiveTab('ranking')} />
        <TabButton active={activeTab === 'viewing'} icon="⊞" label="視聴" onPress={() => setActiveTab('viewing')} />
        <TabButton active={activeTab === 'settings'} icon="⚙︎" label="設定" onPress={() => setActiveTab('settings')} />
      </View>
    </SafeAreaView>
  );
}

function ViewingScreen({
  active,
  streams,
  settings,
  volumes,
  onAdd,
  onRemove,
  onMove,
  onVolume,
  onSettings,
  onImport,
  auth,
  onAuth,
}: {
  active: boolean;
  streams: StreamItem[];
  settings: AppSettings;
  volumes: Record<string, number>;
  onAdd: (platform: PlatformId, channel: string) => void;
  onRemove: (id: string) => void;
  onMove: (index: number, target: number) => void;
  onVolume: (stream: StreamItem, volume: number) => void;
  onSettings: (patch: Partial<AppSettings>) => void;
  onImport: HandoffImporter;
  auth: AuthState;
  onAuth: AuthCommit;
}) {
  const [adding, setAdding] = useState(false);
  const [handoffOpen, setHandoffOpen] = useState(false);
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
    <View style={sharedStyles.screen}>
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
                  viewingActive={active}
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
                  onFocus={setFocused}
                  onReload={reloadStream}
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
        <View style={sharedStyles.iconSegment}>
          <TouchableOpacity
            style={[sharedStyles.iconSegmentButton, settings.layoutMode === 'stacked' && sharedStyles.iconSegmentButtonActive]}
            onPress={() => onSettings({layoutMode: 'stacked'})}>
            <Text style={[sharedStyles.iconSegmentText, settings.layoutMode === 'stacked' && sharedStyles.iconSegmentTextActive]}>▥</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[sharedStyles.iconSegmentButton, settings.layoutMode === 'grid' && sharedStyles.iconSegmentButtonActive]}
            onPress={() => onSettings({layoutMode: 'grid'})}>
            <Text style={[sharedStyles.iconSegmentText, settings.layoutMode === 'grid' && sharedStyles.iconSegmentTextActive]}>▦</Text>
          </TouchableOpacity>
        </View>
        <View style={styles.viewBottomSpacer} />
        <TouchableOpacity accessibilityLabel="引き継ぎ" style={styles.bottomIconButton} onPress={() => setHandoffOpen(true)}>
          <Text style={[styles.bottomIconText, styles.bottomIconLabel]}>QR</Text>
        </TouchableOpacity>
        <TouchableOpacity style={styles.bottomIconButton} onPress={() => setAdding(true)}>
          <Text style={styles.bottomIconText}>＋</Text>
        </TouchableOpacity>
        {streams.length > 0 && (
          <TouchableOpacity accessibilityLabel="更新" style={styles.bottomIconButton} onPress={reloadAll}>
            <Text style={styles.bottomIconText}>↻</Text>
          </TouchableOpacity>
        )}
      </View>

      <HandoffModal
        visible={handoffOpen}
        streams={streams}
        settings={settings}
        onClose={() => setHandoffOpen(false)}
        onImport={onImport}
      />
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
  // iOS と同じ: 2列で詰め、偶数は末尾2本を全幅で縦積み、奇数は末尾1本を全幅にする。
  const bigCount = streams.length % 2 === 0 ? 2 : 1;
  const pairedCount = Math.max(0, streams.length - bigCount);
  return streams.map((stream, index) => ({
    stream,
    index,
    width: index < pairedCount ? '50%' : '100%',
  }));
}

// React.memo: 1セルの状態変化(音量ドラッグ等)で全セルのプレイヤー階層が再レンダー
// されるのを防ぐ。ハンドラ props は親側で useCallback 済みの安定参照を渡す前提。
const StreamCell = React.memo(function StreamCell({
  viewingActive,
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
  viewingActive?: boolean;
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
  onFocus: (stream: StreamItem) => void;
  onReload: (id: string) => void;
  onMove: (index: number, target: number) => void;
  onRemove: (id: string) => void;
  onVolume: (stream: StreamItem, volume: number) => void;
  auth: AuthState;
  onAuth: AuthCommit;
}) {
  const info = platformInfo(stream.platform);
  const [commentOpen, setCommentOpen] = useState(false);
  const [commentText, setCommentText] = useState('');
  const [commentStatus, setCommentStatus] = useState('');
  const [cellLayout, setCellLayout] = useState({width: 0, height: 0});
  const [webViewerCount, setWebViewerCount] = useState<number | null>(null);
  // 並び替えドラッグ中のセルだけ持ち上げスタイルを当てる(iOSのドラッグ影に相当)。
  const [reordering, setReordering] = useState(false);
  const dragOriginRef = useRef(index);
  const dragCurrentRef = useRef(index);
  const webCommentRef = useRef<((text: string) => void) | null>(null);
  const niconicoCommentRef = useRef<NiconicoCommentSender | null>(null);
  // 送信成功後にコメントバーを閉じるタイマー。アンマウント後の setState を防ぐため
  // ref に保持してクリーンアップで必ず解除する。
  const commentCloseTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const scheduleCommentClose = useCallback(() => {
    if (commentCloseTimerRef.current) {
      clearTimeout(commentCloseTimerRef.current);
    }
    commentCloseTimerRef.current = setTimeout(() => {
      commentCloseTimerRef.current = null;
      setCommentOpen(false);
    }, 450);
  }, []);
  useEffect(() => () => {
    if (commentCloseTimerRef.current) {
      clearTimeout(commentCloseTimerRef.current);
    }
  }, []);
  const setWebCommentBridge = useCallback((send: ((text: string) => void) | null) => {
    webCommentRef.current = send;
  }, []);
  const setNiconicoCommentBridge = useCallback((send: NiconicoCommentSender | null) => {
    niconicoCommentRef.current = send;
  }, []);
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
        // 即時スワップだと入れ替わりが視認できない。state 変更前に LayoutAnimation を
        // 仕込み、周囲のセルがスライドして場所を空ける動きにする。
        LayoutAnimation.configureNext(
          LayoutAnimation.create(200, LayoutAnimation.Types.easeInEaseOut, LayoutAnimation.Properties.opacity),
        );
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
          setReordering(true);
        },
        onPanResponderMove: (_, gesture) => updateDragTarget(gesture.dx, gesture.dy),
        onPanResponderRelease: (_, gesture) => {
          updateDragTarget(gesture.dx, gesture.dy);
          setReordering(false);
        },
        onPanResponderTerminate: () => {
          setReordering(false);
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
    if (stream.platform === 'niconico') {
      const send = niconicoCommentRef.current;
      if (!send) {
        setCommentStatus('ニコ生のコメント接続がまだ準備できていません。再読み込み後にもう一度試してください。');
        return;
      }
      send(text)
        .then(() => {
          setCommentText('');
          setCommentStatus('送信しました');
          scheduleCommentClose();
        })
        .catch(error => {
          setCommentStatus(error instanceof Error ? error.message : String(error));
        });
      return;
    }
    let operationBase = auth;
    const commitOperationAuth = async (nextAuth: AuthState) => {
      await onAuth(nextAuth, operationBase);
      operationBase = nextAuth;
    };
    postStreamComment(auth, stream, text, commitOperationAuth)
      .then(async nextAuth => {
        await commitOperationAuth(nextAuth);
        setCommentText('');
        setCommentStatus('送信しました');
        scheduleCommentClose();
      })
      .catch(error => {
        if (webCommentRef.current) {
          webCommentRef.current(text);
          setCommentStatus('Webチャット入力を試行しました（未確認）');
          return;
        }
        setCommentStatus(error instanceof Error ? error.message : String(error));
      });
  }, [auth, commentText, onAuth, scheduleCommentClose, stream]);

  // React.memo の効果を保つため、セル固有ハンドラはここで安定化して子に渡す。
  const handleFocus = useCallback(() => onFocus(stream), [onFocus, stream]);
  const handleReload = useCallback(() => onReload(stream.id), [onReload, stream.id]);
  const handleRemove = useCallback(() => onRemove(stream.id), [onRemove, stream.id]);
  const handleCellLayout = useCallback(
    (event: {nativeEvent: {layout: {width: number; height: number}}}) => setCellLayout(event.nativeEvent.layout),
    [],
  );

  return (
    <View style={[styles.streamCell, reordering && styles.streamCellReordering]} onLayout={handleCellLayout}>
      <View style={styles.player} onTouchStart={showChrome}>
        {paused ? (
          <View style={sharedStyles.playerPlaceholder}>
            <Text style={sharedStyles.playerStatus}>フォーカス表示中</Text>
          </View>
        ) : (
          <StreamPlayer
            viewingActive={viewingActive}
            stream={stream}
            settings={settings}
            streamCount={streamCount}
            paused={paused}
            muted={muted || volume <= 0}
            volume={volume}
            reloadKey={reloadKey}
            onWebCommentBridge={setWebCommentBridge}
            onNiconicoCommentBridge={setNiconicoCommentBridge}
            onViewerCount={setWebViewerCount}
          />
        )}
        <View style={sharedStyles.playerChrome} pointerEvents="box-none">
          {!chromeVisible && <Pressable style={sharedStyles.chromeRevealTouch} onPress={showChrome} />}
          {settings.showViewerCount && (
            <ViewerCountBadge stream={stream} externalCount={webViewerCount} visible={chromeVisible} active={viewingActive !== false} />
          )}
          <View
            style={[sharedStyles.autoHideChrome, !chromeVisible && sharedStyles.autoHideChromeHidden]}
            pointerEvents={chromeVisible ? 'box-none' : 'none'}>
            <View style={styles.cellTopControls} pointerEvents="box-none">
              {/* 「□」は意味が伝わらない。コメント欄トグルは文字ラベルにし、絵文字の
                  吹き出し(カラービットマップ化してtint不能)は使わない。 */}
              <TouchableOpacity
                accessibilityLabel="コメント入力"
                style={[sharedStyles.overlayButton, commentOpen && styles.overlayButtonActive]}
                onPress={() => setCommentOpen(current => !current)}>
                <Text style={[styles.overlayLabel, commentOpen && styles.overlayIconActive]}>コメ</Text>
              </TouchableOpacity>
              <TouchableOpacity accessibilityLabel="拡大表示" style={sharedStyles.overlayButton} onPress={handleFocus}>
                <Text style={sharedStyles.overlayIcon}>⤢</Text>
              </TouchableOpacity>
              <TouchableOpacity accessibilityLabel="再読み込み" style={sharedStyles.overlayButton} onPress={handleReload}>
                <Text style={sharedStyles.overlayIcon}>↻</Text>
              </TouchableOpacity>
              <TouchableOpacity accessibilityLabel="削除" style={sharedStyles.overlayButton} onPress={handleRemove}>
                <Text style={sharedStyles.overlayIcon}>✕</Text>
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
});

const styles = StyleSheet.create({
  app: {
    flex: 1,
    backgroundColor: '#05070a',
  },
  content: {
    flex: 1,
  },
  tabPanel: {
    flex: 1,
  },
  hiddenViewingPanel: {
    position: 'absolute',
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
    opacity: 0,
  },
  // iOS の translucent tab bar + hairline に寄せる。アクティブはアクセント色の
  // ティント + 上端インジケータで示し、背景ピルは使わない。
  tabBar: {
    minHeight: 60,
    paddingHorizontal: 8,
    paddingTop: 3,
    paddingBottom: 6,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: 'rgba(255,255,255,0.16)',
    backgroundColor: 'rgba(9,13,18,0.92)',
    flexDirection: 'row',
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
  viewBottomSpacer: {
    flex: 1,
  },
  bottomIconButton: {
    width: 40,
    height: 36,
    marginLeft: 8,
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
  bottomIconLabel: {
    fontSize: 14,
    lineHeight: 18,
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
  // 並び替えドラッグ中のセル: 半透明 + アクセント枠 + 僅かな縮小で「持ち上げ中」を示す。
  streamCellReordering: {
    opacity: 0.75,
    borderWidth: 1.5,
    borderColor: '#67a8ff',
    transform: [{scale: 0.97}],
  },
  player: {
    aspectRatio: 16 / 9,
    backgroundColor: '#000',
    position: 'relative',
  },
  cellTopControls: {
    position: 'absolute',
    top: 8,
    right: 8,
    flexDirection: 'row',
  },
  // コメントバー展開中のトグルはアクセント背景で「開いている」ことを示す。
  overlayButtonActive: {
    backgroundColor: 'rgba(47,140,255,0.85)',
  },
  // 「コメ」のような 2 文字ラベル用。記号アイコンと同じ濃さ/重さで揃える。
  overlayLabel: {
    color: 'rgba(255,255,255,0.92)',
    fontSize: 11,
    fontWeight: '700',
    lineHeight: 14,
  },
  overlayIconActive: {
    color: '#fff',
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
});
