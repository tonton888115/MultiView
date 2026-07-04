import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {
  ActivityIndicator,
  Alert,
  AppState,
  Animated,
  Image,
  Modal,
  ScrollView,
  PanResponder,
  Pressable,
  Share,
  StatusBar,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  TouchableOpacity,
  useWindowDimensions,
  View,
  Linking,
} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import AsyncStorage from '@react-native-async-storage/async-storage';
import {WebView, type WebViewMessageEvent} from 'react-native-webview';
import {DanmakuOverlay} from './src/DanmakuOverlay';
import {GiftOverlay} from './src/GiftOverlay';
import {NativeHlsPlayer} from './src/NativeHlsPlayer';
import {
  AUTH_STORAGE_KEY,
  PENDING_DEVICE_OAUTH_STORAGE_KEY,
  PENDING_OAUTH_STORAGE_KEY,
  authStatus,
  completeOAuthRedirect,
  createOAuthURLSingleFlight,
  createOAuthStart,
  defaultAuthState,
  deviceOAuthErrorDisposition,
  hasUsableAuthSession,
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
  signOut,
  updateAuthConfig,
  type AuthState,
  type OAuthService,
  type PendingDeviceOAuth,
  type PendingOAuth,
} from './src/auth';
import {compactHandoffCode, decodeHandoff, handoffURL} from './src/handoff';
import {encodeHandoffQrPngBase64, isHandoffQrAvailable, scanHandoffQr} from './src/NativeHandoffQr';
import {
  chatURL,
  desktopUserAgent,
  effectiveQuality,
  makeStream,
  mobileUserAgent,
  resolvePlaybackSource,
  webStreamURL,
  youtubeIframeHTML,
} from './src/playback';
import type {AppSettings, PlatformId, PlaybackSource, Source, StreamItem, TabId} from './src/types';
import {isAdBlockedURL} from './src/adblock';
import {fetchViewerCount} from './src/viewerCount';
import {injectWebComment, sourceBridgeScript, webFallbackScript} from './src/webInject';
import {setRaidHandler} from './src/raidFollow';
import {niconicoOriginURL, niconicoPostCommentScript, niconicoQuality, niconicoSessionScript, niconicoSupportPresentation} from './src/niconico';
import {twitcastingSessionScript} from './src/twitcasting';
import {pushNiconicoComment} from './src/niconicoComments';
import {publishGiftEvent} from './src/giftEvents';
import {startPlaybackService, stopPlaybackService} from './src/playbackService';
import {useNetworkType} from './src/network';
import {parseStreamURL} from './src/streamURL';
import {appSafeAreaEdges, focusedPaneLayout} from './src/layout';
import {useRecoveringNativeSession} from './src/useRecoveringNativeSession';
import {autoReloadDelayMs, nativeFirstFrameTimeoutMs, nativeSourceRecoveryDelayMs, shouldFallbackForMissingNativeFrame, shouldRecoverNativeSource, shouldReloadOnViewActivation, shouldRenderNativeSession, shouldRestartSessionOnAppState} from './src/sessionRecovery';

const STREAMS_KEY = 'multiview.android.streams.v2';
const LEGACY_STREAMS_KEY = 'multiview.android.streams.v1';
const SETTINGS_KEY = 'multiview.android.settings.v2';
const LEGACY_SETTINGS_KEY = 'multiview.android.settings.v1';
const VOLUMES_KEY = 'multiview.android.volumes.v1';
const chromeAutoHideDelayMs = 2400;

type AuthCommit = (
  next: AuthState,
  base: AuthState,
  overwriteConflicts?: readonly OAuthService[],
) => Promise<AuthState>;

type NiconicoCommentSender = (text: string) => Promise<void>;
type HandoffImportMode = 'replace' | 'append';
type HandoffImporter = (streams: StreamItem[], settings: Partial<AppSettings>, mode: HandoffImportMode) => void;

const platformIds: PlatformId[] = ['kick', 'twitch', 'youtube', 'niconico', 'twitcasting'];
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
    if (hydrated) {
      AsyncStorage.setItem(VOLUMES_KEY, JSON.stringify(volumes)).catch(() => undefined);
    }
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
          <SourceBrowser sources={orderedSources(followingSources, settings)} onAdd={addStream} />
        )}
        {activeTab === 'ranking' && (
          <SourceBrowser sources={orderedSources(rankingSources, settings)} onAdd={addStream} />
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
      if (url && addParsed(url)) {
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

function HandoffModal({
  visible,
  streams,
  settings,
  onClose,
  onImport,
}: {
  visible: boolean;
  streams: StreamItem[];
  settings: AppSettings;
  onClose: () => void;
  onImport: HandoffImporter;
}) {
  const [mode, setMode] = useState<'send' | 'receive'>('send');
  const [handoff, setHandoff] = useState('');
  const [handoffQrPng, setHandoffQrPng] = useState<string | null>(null);
  const compactCode = useMemo(() => compactHandoffCode(streams, settings.layoutMode), [settings.layoutMode, streams]);
  // QRの中身はURL形式にする。iOSのHandoffPayload.decodeはURL形式も受理し、
  // OS標準カメラで読んだ場合もディープリンクとしてこのアプリが開く(最大互換)。
  const handoffUrl = useMemo(() => handoffURL(streams, settings.layoutMode), [settings.layoutMode, streams]);
  const exportText = useMemo(
    () =>
      JSON.stringify(
        {
          version: 2,
          streams,
          settings,
          compactCode,
          url: handoffUrl,
        },
        null,
        2,
      ),
    [compactCode, handoffUrl, settings, streams],
  );

  useEffect(() => {
    if (visible) {
      setMode('send');
    }
  }, [visible]);

  useEffect(() => {
    let cancelled = false;
    if (!visible || !streams.length) {
      setHandoffQrPng(null);
      return;
    }
    encodeHandoffQrPngBase64(handoffUrl, 512).then(png => {
      if (!cancelled) {
        setHandoffQrPng(png);
      }
    });
    return () => {
      cancelled = true;
    };
  }, [handoffUrl, streams.length, visible]);

  // iOS HandoffController.handleReceived と同じ受け取りフロー:
  // 解読 → タブ数を提示 → 置き換える(設定も反映) / 追加する(タブのみ) / キャンセル。
  const receiveHandoff = (raw: string): boolean => {
    let decoded: ReturnType<typeof decodeHandoff>;
    try {
      decoded = decodeHandoff(raw);
    } catch {
      Alert.alert('受け取れませんでした', 'コード/QRを認識できませんでした。JSON、iOS引き継ぎコード、multiview:// URL のいずれかを確認してください。');
      return false;
    }
    const nextStreams = decoded.streams.map(stream => makeStream(stream.platform, stream.channel));
    if (!nextStreams.length) {
      Alert.alert('タブが空です', '受け取れる視聴タブがありませんでした。');
      return false;
    }
    Alert.alert(`${nextStreams.length} タブを受け取りました`, 'この端末の視聴タブをどうしますか?', [
      {
        text: '置き換える',
        style: 'destructive',
        onPress: () => {
          onImport(nextStreams, decoded.settings, 'replace');
          setHandoff('');
          onClose();
        },
      },
      {
        text: '追加する',
        onPress: () => {
          onImport(nextStreams, {}, 'append');
          setHandoff('');
          onClose();
        },
      },
      {text: 'キャンセル', style: 'cancel'},
    ]);
    return true;
  };

  const importPayload = () => {
    receiveHandoff(handoff);
  };

  const scanHandoff = async () => {
    const scanned = await scanHandoffQr();
    if (scanned) {
      receiveHandoff(scanned);
    }
  };

  const shareHandoff = async () => {
    try {
      await Share.share({message: handoffUrl});
    } catch {
      // 共有シートのキャンセルは無視する。
    }
  };

  return (
    <Modal visible={visible} animationType="slide" onRequestClose={onClose}>
      <SafeAreaView style={styles.modal} edges={appSafeAreaEdges}>
        <View style={styles.modalHeader}>
          <Text style={styles.modalTitle}>引き継ぎ</Text>
          <TouchableOpacity onPress={onClose}>
            <Text style={styles.closeText}>閉じる</Text>
          </TouchableOpacity>
        </View>
        <View style={styles.handoffModeTabs}>
          <TouchableOpacity
            style={[styles.handoffModeButton, mode === 'send' && styles.handoffModeButtonActive]}
            onPress={() => setMode('send')}>
            <Text style={[styles.handoffModeText, mode === 'send' && styles.handoffModeTextActive]}>送る</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.handoffModeButton, mode === 'receive' && styles.handoffModeButtonActive]}
            onPress={() => setMode('receive')}>
            <Text style={[styles.handoffModeText, mode === 'receive' && styles.handoffModeTextActive]}>受け取る</Text>
          </TouchableOpacity>
        </View>
        {mode === 'send' ? (
          <ScrollView style={styles.handoffBody} contentContainerStyle={styles.handoffContent}>
            {streams.length > 0 && handoffQrPng ? (
              <>
                <Text style={styles.settingNote}>
                  この端末で開いている {streams.length} タブのQRです。もう一方の端末で「受け取る」から読み取ってください。
                </Text>
                <Image
                  source={{uri: `data:image/png;base64,${handoffQrPng}`}}
                  style={styles.handoffQr}
                  resizeMode="contain"
                />
                <TouchableOpacity style={styles.fullButton} onPress={shareHandoff}>
                  <Text style={styles.fullButtonText}>共有 / コピー</Text>
                </TouchableOpacity>
                <Text style={styles.settingNote}>iOS互換の短いコードとURLも含めて出力します。</Text>
                <TextInput value={exportText} editable={false} multiline style={[styles.textArea, styles.readOnly]} />
              </>
            ) : (
              <Text style={styles.settingNote}>開いているタブがありません。</Text>
            )}
          </ScrollView>
        ) : (
          <ScrollView style={styles.handoffBody} contentContainerStyle={styles.handoffContent}>
            <Text style={styles.settingNote}>もう一方の端末の「送る」QRを読み取るか、コピーしたコードを貼り付けて受け取ります。</Text>
            {isHandoffQrAvailable() && (
              <TouchableOpacity style={styles.fullButton} onPress={scanHandoff}>
                <Text style={styles.fullButtonText}>QRをスキャン</Text>
              </TouchableOpacity>
            )}
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
          </ScrollView>
        )}
      </SafeAreaView>
    </Modal>
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

function StreamCell({
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
  onFocus: () => void;
  onReload: () => void;
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

  return (
    <View style={styles.streamCell} onLayout={event => setCellLayout(event.nativeEvent.layout)}>
      <View style={styles.player} onTouchStart={showChrome}>
        {paused ? (
          <View style={styles.playerPlaceholder}>
            <Text style={styles.playerStatus}>フォーカス表示中</Text>
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
  viewingActive = true,
  stream,
  settings,
  streamCount,
  paused,
  muted,
  volume,
  reloadKey,
  onWebCommentBridge,
  onNiconicoCommentBridge,
  onViewerCount,
}: {
  viewingActive?: boolean;
  stream: StreamItem;
  settings: AppSettings;
  streamCount: number;
  paused: boolean;
  muted: boolean;
  volume: number;
  reloadKey: number;
  onWebCommentBridge?: (send: ((text: string) => void) | null) => void;
  onNiconicoCommentBridge?: (send: NiconicoCommentSender | null) => void;
  onViewerCount?: (count: number) => void;
}) {
  const [source, setSource] = useState<PlaybackSource | null>(null);
  const [, setPlayerStatus] = useState('待機中');
  const webRef = useRef<WebView>(null);
  const streamRef = useRef(stream);
  const settingsRef = useRef(settings);
  const streamCountRef = useRef(streamCount);
  const networkType = useNetworkType();
  const playbackQuality = effectiveQuality(settings, streamCount, networkType);
  streamRef.current = stream;
  settingsRef.current = settings;
  streamCountRef.current = streamCount;
  // ネイティブプレイヤーの error/ended を受けてのデバウンス自動復旧。
  // iOS の .multiViewPlaybackErrored と同じく 45 秒に 1 回までに制限してループを防ぐ。
  // ただしイベントを「捨てる」と、致命的エラー(STATE_IDLE)後はネイティブ側が二度と
  // イベントを出さないため永久凍結する。窓内のイベントは窓明けへ繰り延べて必ず実行する。
  const [autoReloadTick, setAutoReloadTick] = useState(0);
  const lastAutoReloadRef = useRef(0);
  const autoReloadTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const previouslyViewingActiveRef = useRef(viewingActive);
  // YouTube が native HLS を取れず取得中/iframe に留まったとき、静かに再解決して HLS へ
  // 昇格させるための内部チック。retry 回数は youtubeRetryRef で上限管理する。
  const [youtubeUpgradeTick, setYoutubeUpgradeTick] = useState(0);
  const youtubeRetryRef = useRef(0);
  // Twitch/Kick がエラー/Webフォールバックに落ちたままにならないよう、静かに再解決
  // して native HLS が取れたときだけ差し替えるための内部チック。
  const [nativeRecoveryTick, setNativeRecoveryTick] = useState(0);
  const clearAutoReloadTimer = useCallback(() => {
    if (autoReloadTimerRef.current) {
      clearTimeout(autoReloadTimerRef.current);
      autoReloadTimerRef.current = null;
    }
  }, []);
  const scheduleAutoReload = useCallback(() => {
    if (autoReloadTimerRef.current) {
      return;
    }
    autoReloadTimerRef.current = setTimeout(() => {
      autoReloadTimerRef.current = null;
      lastAutoReloadRef.current = Date.now();
      setAutoReloadTick(tick => tick + 1);
    }, autoReloadDelayMs(Date.now(), lastAutoReloadRef.current));
  }, []);

  useEffect(() => clearAutoReloadTimer, [clearAutoReloadTimer]);

  useEffect(() => {
    const previouslyActive = previouslyViewingActiveRef.current;
    previouslyViewingActiveRef.current = viewingActive;
    if (shouldReloadOnViewActivation(previouslyActive, viewingActive)) {
      // The viewing panel remains mounted beneath other tabs. Android may
      // detach a TextureView or fail a hidden HLS session while it is opaque.
      // Re-enter through the same full reload boundary as the manual button.
      clearAutoReloadTimer();
      lastAutoReloadRef.current = Date.now();
      setAutoReloadTick(tick => tick + 1);
    }
  }, [clearAutoReloadTimer, viewingActive]);

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
    const currentStream = streamRef.current;
    if (currentStream.platform === 'niconico' || currentStream.platform === 'twitcasting') {
      // ニコ生/ツイキャスはネイティブ視聴セッションが自前で扱う。
      return;
    }
    let cancelled = false;
    setSource(null);
    setPlayerStatus('取得中');
    // resolvePlaybackSource は内部で全例外を error ソースへ畳み込み、reject しない
    // (YouTube を Web ページへ落とさないガードも playback.ts 側にある)。
    resolvePlaybackSource(currentStream, settingsRef.current, streamCountRef.current)
      .then(next => {
        if (!cancelled) {
          setSource(next);
          setPlayerStatus(next.status);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [
    stream.id,
    stream.platform,
    stream.channel,
    settings.youtubePreferIframe,
    settings.youtubeStableBuffer,
    reloadKey,
    autoReloadTick,
  ]);

  // 配信切替/手動更新で YouTube の再試行カウンタをリセット。
  useEffect(() => {
    youtubeRetryRef.current = 0;
  }, [stream.id, reloadKey]);

  // YouTube は映像のみ HLS 抽出が最優先。ID 解決や HLS 抽出に失敗して取得中/iframe に
  // 留まったら、画面を Web ページへ落とさず、バックグラウンドで数回だけ静かに再解決し、
  // native HLS が取れたときだけ差し替える(成功時のみ setSource = ちらつき無し)。
  useEffect(() => {
    if (stream.platform !== 'youtube' || !source || source.kind === 'native') {
      youtubeRetryRef.current = 0;
      return;
    }
    // Web ページへは絶対に落とさず、映像のみ(native HLS)が取れるまで粘る。
    // 初回数回は素早く(6s)、以降はゆっくり(20s)で再解決し続ける(YouTube への負荷も抑える)。
    const delay = youtubeRetryRef.current < 3 ? 6000 : 20000;
    let cancelled = false;
    const timer = setTimeout(async () => {
      youtubeRetryRef.current += 1;
      try {
        const next = await resolvePlaybackSource(streamRef.current, settingsRef.current, streamCountRef.current);
        if (cancelled) {
          return;
        }
        if (next.kind === 'native') {
          setSource(next);
          setPlayerStatus(next.status);
        } else {
          setYoutubeUpgradeTick(tick => tick + 1);
        }
      } catch {
        if (!cancelled) {
          setYoutubeUpgradeTick(tick => tick + 1);
        }
      }
    }, delay);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [source, stream.platform, youtubeUpgradeTick]);

  // Twitch/Kick は再解決失敗やオフライン判定でエラー/Webフォールバックへ落ちると、
  // 回線復帰後も native HLS へ戻る経路が無かった(iOS は StallWatchdog+再取得ラダー
  // が再接続する)。YouTube と同じく静かに再解決し、native が取れたときだけ差し替える。
  useEffect(() => {
    if (!source || !shouldRecoverNativeSource(stream.platform, source.kind)) {
      return;
    }
    let cancelled = false;
    const timer = setTimeout(async () => {
      try {
        const next = await resolvePlaybackSource(streamRef.current, settingsRef.current, streamCountRef.current);
        if (cancelled) {
          return;
        }
        if (next.kind === 'native') {
          setSource(next);
          setPlayerStatus(next.status);
        } else {
          setNativeRecoveryTick(tick => tick + 1);
        }
      } catch {
        if (!cancelled) {
          setNativeRecoveryTick(tick => tick + 1);
        }
      }
    }, nativeSourceRecoveryDelayMs);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [source, stream.platform, nativeRecoveryTick]);

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
        onCommentBridge={onNiconicoCommentBridge}
        onViewerCount={onViewerCount}
      />
    );
  }

  if (stream.platform === 'twitcasting') {
    return (
      <TwitcastingNativePlayer
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
          maxBitrate={playbackQuality === 'economy' ? 900000 : 0}
          resizeMode="contain"
          onPlayerEvent={event => {
            const payload = event.nativeEvent;
            setPlayerStatus(payload.type === 'error' ? `エラー: ${payload.message}` : payload.message);
            // 'idle' は致命的エラー後の停止状態。error イベントが失われても復旧に繋ぐ。
            if (payload.type === 'error' || payload.message === 'ended' || payload.message === 'idle') {
              scheduleAutoReload();
            }
          }}
        />
        <DanmakuOverlay stream={stream} settings={settings} />
        <GiftOverlay stream={stream} settings={settings} />
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
        <DanmakuOverlay stream={stream} settings={settings} />
        <GiftOverlay stream={stream} settings={settings} />
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
        <GiftOverlay stream={stream} settings={settings} />
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
  onCommentBridge,
  onViewerCount,
}: {
  stream: StreamItem;
  settings: AppSettings;
  streamCount: number;
  paused: boolean;
  muted: boolean;
  volume: number;
  reloadKey: number;
  onCommentBridge?: (send: NiconicoCommentSender | null) => void;
  onViewerCount?: (count: number) => void;
}) {
  const [hls, setHls] = useState<{url: string; cookieHeader?: string; sessionKey: string} | null>(null);
  const [nativeFrameReady, setNativeFrameReady] = useState(false);
  const [sessionEndedMessage, setSessionEndedMessage] = useState<string | null>(null);
  const [nativeFallbackReason, setNativeFallbackReason] = useState<string | null>(null);
  const hlsRef = useRef<typeof hls>(hls);
  const sessionWebViewRef = useRef<WebView>(null);
  const commentRequestSequenceRef = useRef(0);
  const pendingCommentRequestsRef = useRef(new Map<string, {
    resolve: () => void;
    reject: (error: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  }>());
  const networkType = useNetworkType();
  const playbackQuality = effectiveQuality(settings, streamCount, networkType);
  const recovery = useRecoveringNativeSession(
    `${stream.channel}:${playbackQuality}:${settings.niconicoLowLatency}:${reloadKey}`,
  );
  const {
    sessionReloadTick,
    useWebFallback,
    scheduleReconnect,
    restartSessionNow,
    startSessionWatchdog,
    markSessionResolved,
    handlePlayerStatus,
  } = recovery;
  const sessionKey = `${stream.channel}:${playbackQuality}:${settings.niconicoLowLatency}:${reloadKey}:${sessionReloadTick}`;
  const activeSessionKeyRef = useRef(sessionKey);
  const appStateRef = useRef(AppState.currentState);
  activeSessionKeyRef.current = sessionKey;
  hlsRef.current = hls;
  const shouldUseOfficialWebFallback = useWebFallback || nativeFallbackReason != null;

  const rejectPendingComments = useCallback((message: string) => {
    pendingCommentRequestsRef.current.forEach(pending => {
      clearTimeout(pending.timer);
      pending.reject(new Error(message));
    });
    pendingCommentRequestsRef.current.clear();
  }, []);

  const postNiconicoComment = useCallback<NiconicoCommentSender>(text => {
    const webView = sessionWebViewRef.current;
    if (!webView) {
      return Promise.reject(new Error('ニコ生のコメント接続がまだ準備できていません。再読み込み後にもう一度試してください。'));
    }
    const requestId = `${Date.now()}:${++commentRequestSequenceRef.current}`;
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        pendingCommentRequestsRef.current.delete(requestId);
        reject(new Error('ニコ生コメントの送信確認がタイムアウトしました。再読み込み後にもう一度試してください。'));
      }, 5000);
      pendingCommentRequestsRef.current.set(requestId, {resolve, reject, timer});
      try {
        webView.injectJavaScript(niconicoPostCommentScript(requestId, text));
      } catch (error) {
        clearTimeout(timer);
        pendingCommentRequestsRef.current.delete(requestId);
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }, []);

  useEffect(() => {
    onCommentBridge?.(postNiconicoComment);
    return () => onCommentBridge?.(null);
  }, [onCommentBridge, postNiconicoComment]);

  useEffect(() => {
    const subscription = AppState.addEventListener('change', nextState => {
      const previousState = appStateRef.current;
      appStateRef.current = nextState;
      if (shouldRestartSessionOnAppState(previousState, nextState)) {
        // ExoPlayer can keep advancing while its HLS/socket/video surface is no
        // longer usable after a long background stay. A fresh browser-origin
        // session is the same recovery that the manual reload button performs.
        restartSessionNow();
      }
    });
    return () => subscription.remove();
  }, [restartSessionNow]);

  useEffect(() => () => {
    rejectPendingComments('ニコ生のコメント接続が再初期化されました。もう一度送信してください。');
  }, [rejectPendingComments, sessionKey]);

  useEffect(() => {
    setHls(null);
    setNativeFrameReady(false);
    setSessionEndedMessage(null);
    setNativeFallbackReason(null);
    startSessionWatchdog();
  }, [sessionKey, startSessionWatchdog]);

  useEffect(() => {
    setNativeFrameReady(false);
  }, [hls?.url, hls?.sessionKey]);

  useEffect(() => {
    if (!hls || hls.sessionKey !== sessionKey || shouldUseOfficialWebFallback || nativeFrameReady) {
      return;
    }
    const timer = setTimeout(() => {
      if (shouldFallbackForMissingNativeFrame(nativeFrameReady, nativeFirstFrameTimeoutMs)) {
        setHls(null);
        restartSessionNow();
      }
    }, nativeFirstFrameTimeoutMs);
    return () => clearTimeout(timer);
  }, [hls, nativeFrameReady, restartSessionNow, sessionKey, shouldUseOfficialWebFallback]);

  const onSessionMessage = useCallback(
    (event: WebViewMessageEvent, eventSessionKey: string) => {
      if (eventSessionKey !== activeSessionKeyRef.current) {
        return;
      }
      let payload: any;
      try {
        payload = JSON.parse(event.nativeEvent.data);
      } catch {
        return;
      }
      if (payload?.type === 'niconicoCommentPostResult' && typeof payload.requestId === 'string') {
        const pending = pendingCommentRequestsRef.current.get(payload.requestId);
        if (!pending) {
          return;
        }
        clearTimeout(pending.timer);
        pendingCommentRequestsRef.current.delete(payload.requestId);
        if (payload.ok === true) {
          pending.resolve();
        } else {
          pending.reject(new Error(
            typeof payload.message === 'string' && payload.message.trim()
              ? payload.message.trim()
              : 'ニコ生コメントを送信できませんでした',
          ));
        }
      } else if (payload?.type === 'niconicoStream' && typeof payload.hlsUrl === 'string') {
        markSessionResolved();
        setSessionEndedMessage(null);
        setNativeFallbackReason(null);
        setHls({url: payload.hlsUrl, cookieHeader: payload.cookies || undefined, sessionKey: eventSessionKey});
      } else if (payload?.type === 'niconicoComment' && typeof payload.text === 'string') {
        pushNiconicoComment(stream.channel, {
          id: typeof payload.id === 'string' ? payload.id : undefined,
          text: payload.text,
        });
      } else if (payload?.type === 'niconicoEvent' && typeof payload.text === 'string') {
        // iOS parity: support events are dedicated overlays, never ordinary
        // comments/danmaku. Generic visitor notices are filtered in the NDGR
        // parser before reaching this branch.
        const kind = payload.kind === 'gift' || payload.kind === 'nicoad' || payload.kind === 'notification'
          ? payload.kind
          : null;
        if (kind && niconicoSupportPresentation(kind, settings) === 'overlay') {
          const createdAt = Date.now();
          const id = typeof payload.id === 'string' && payload.id
            ? `nico-event:${kind}:${payload.id}`
            : `nico-event:${kind}:${payload.text}:${Math.floor(createdAt / 5000)}`;
          if (kind === 'gift') {
            publishGiftEvent(stream.id, {
              id,
              platform: stream.platform,
              text: payload.text,
              headline: 'ギフト',
              kind: 'gift',
              createdAt,
            });
          } else if (kind === 'nicoad') {
            publishGiftEvent(stream.id, {
              id,
              platform: stream.platform,
              text: payload.text,
              headline: 'ニコニコ広告',
              kind: 'nicoad',
              createdAt,
            });
          } else {
            publishGiftEvent(stream.id, {
              id,
              platform: stream.platform,
              text: payload.text,
              headline: 'お知らせ',
              kind: 'notification',
              createdAt,
            });
          }
        }
      } else if (payload?.type === 'niconicoEnded') {
        rejectPendingComments('番組が終了したためコメントを送信できません');
        markSessionResolved();
        setHls(null);
        setNativeFallbackReason(null);
        const message = typeof payload.message === 'string' && payload.message.trim()
          ? payload.message.trim()
          : '番組が終了しました';
        setSessionEndedMessage(`${message}\n自動では閉じません`);
      } else if (payload?.type === 'niconicoNativeBlocked') {
        rejectPendingComments(
          typeof payload.message === 'string' && payload.message.trim()
            ? payload.message.trim()
            : 'ニコ生コメントを送信できません',
        );
        markSessionResolved();
        setHls(null);
        setNativeFrameReady(false);
        setSessionEndedMessage(null);
        setNativeFallbackReason(typeof payload.message === 'string' && payload.message.trim()
          ? payload.message.trim()
          : '公式プレイヤーで表示します');
      } else if (payload?.type === 'niconicoCommentBridgeError') {
        // The injected bridge has already restarted only its watch WS/NDGR
        // owner. Keep the healthy HLS player mounted while comments recover.
        return;
      } else if (payload?.type === 'niconicoError') {
        if (hlsRef.current) {
          return;
        }
        scheduleReconnect();
      }
    },
    [
      stream.id,
      stream.channel,
      stream.platform,
      settings.showGiftEffects,
      settings.niconicoShowGift,
      settings.niconicoShowNicoad,
      settings.niconicoShowNotification,
      markSessionResolved,
      rejectPendingComments,
      scheduleReconnect,
    ],
  );

  // niconico は RN の直接 fetch/WS を拒否するため、視聴セッションは niconico オリジンを
  // 読み込んだ隠し WebView 内で実行し、HLS uri を postMessage で受け取る(keepSeatも内部で継続)。
  const sessionWebView =
    !nativeFallbackReason && !sessionEndedMessage ? (
      <WebView
        ref={sessionWebViewRef}
        key={`niconico-session:${sessionKey}`}
        source={{uri: niconicoOriginURL}}
        userAgent={desktopUserAgent}
        javaScriptEnabled
        domStorageEnabled
        sharedCookiesEnabled
        thirdPartyCookiesEnabled
        setSupportMultipleWindows={false}
        injectedJavaScript={niconicoSessionScript(stream.channel, niconicoQuality(playbackQuality))}
        onMessage={event => onSessionMessage(event, sessionKey)}
        onError={scheduleReconnect}
        onHttpError={scheduleReconnect}
        onRenderProcessGone={scheduleReconnect}
        containerStyle={styles.hiddenBridgeWeb}
        style={styles.hiddenBridgeWeb}
      />
    ) : null;

  if (sessionEndedMessage) {
    return (
      <View style={styles.playerPlaceholder}>
        <Text style={styles.playerStatus}>{sessionEndedMessage}</Text>
      </View>
    );
  }

  if (hls && hls.sessionKey === sessionKey && shouldRenderNativeSession(true, shouldUseOfficialWebFallback)) {
    return (
      <>
        {sessionWebView}
        <NativeHlsPlayer
          key={`${hls.url}:${reloadKey}:${sessionReloadTick}`}
          style={styles.nativePlayer}
          sourceUrl={hls.url}
          headers={{
            ...(hls.cookieHeader ? {Cookie: hls.cookieHeader} : {}),
            'User-Agent': mobileUserAgent,
            Referer: webStreamURL(stream),
            Origin: 'https://live.nicovideo.jp',
            'Accept-Language': 'ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6',
          }}
          paused={paused}
          muted={muted}
          volume={volume}
          liveTargetOffsetMs={settings.niconicoLowLatency ? 2000 : 6000}
          maxBitrate={playbackQuality === 'economy' ? 900000 : 0}
          resizeMode="contain"
          onPlayerEvent={event => {
            const payload = event.nativeEvent;
            if (payload.type === 'firstFrame') {
              setNativeFrameReady(true);
            }
            if (payload.type === 'error' || payload.message === 'ended') {
              setHls(null);
            }
            handlePlayerStatus(payload.type, payload.message, paused);
          }}
        />
        <DanmakuOverlay stream={stream} settings={settings} />
        <GiftOverlay stream={stream} settings={settings} />
      </>
    );
  }

  if (shouldUseOfficialWebFallback) {
    return (
      <>
        {sessionWebView}
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
        <GiftOverlay stream={stream} settings={settings} />
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

function TwitcastingNativePlayer({
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
  const [hls, setHls] = useState<{url: string; cookieHeader: string} | null>(null);
  const [nativeFrameReady, setNativeFrameReady] = useState(false);
  const [missingNativeFrameFallback, setMissingNativeFrameFallback] = useState(false);
  const networkType = useNetworkType();
  const playbackQuality = effectiveQuality(settings, streamCount, networkType);
  const channel = stream.channel.trim();
  const recovery = useRecoveringNativeSession(`${channel}:${playbackQuality}:${reloadKey}`);
  const {
    sessionReloadTick,
    useWebFallback,
    scheduleReconnect,
    restartSessionNow,
    startSessionWatchdog,
    markSessionResolved,
    handlePlayerStatus,
  } = recovery;
  const sessionKey = `${channel}:${playbackQuality}:${reloadKey}:${sessionReloadTick}`;
  const activeSessionKeyRef = useRef(sessionKey);
  const appStateRef = useRef(AppState.currentState);
  activeSessionKeyRef.current = sessionKey;

  useEffect(() => {
    const subscription = AppState.addEventListener('change', nextState => {
      const previousState = appStateRef.current;
      appStateRef.current = nextState;
      if (shouldRestartSessionOnAppState(previousState, nextState)) {
        // Niconico と同じ理由: 長いバックグラウンド滞在後は HLS/セッション/映像 surface が
        // 使えないまま ExoPlayer が進み続けることがある。手動リロードと同じ完全復帰を行う。
        restartSessionNow();
      }
    });
    return () => subscription.remove();
  }, [restartSessionNow]);

  useEffect(() => {
    setHls(null);
    setNativeFrameReady(false);
    setMissingNativeFrameFallback(false);
    startSessionWatchdog();
  }, [sessionKey, startSessionWatchdog]);

  useEffect(() => {
    setNativeFrameReady(false);
    setMissingNativeFrameFallback(false);
  }, [hls?.url]);

  useEffect(() => {
    if (!hls || useWebFallback || nativeFrameReady || missingNativeFrameFallback) {
      return;
    }
    const timer = setTimeout(() => {
      if (shouldFallbackForMissingNativeFrame(nativeFrameReady, nativeFirstFrameTimeoutMs)) {
        // Niconico と同じく完全なセッション再取得へ回す。恒久的な Web フォールバック固定
        // (hidden session まで外れて native へ戻れなくなる)にはしない。3回失敗すれば
        // useWebFallback が一時フォールバックを出しつつ native 再試行を継続する。
        setHls(null);
        restartSessionNow();
      }
    }, nativeFirstFrameTimeoutMs);
    return () => clearTimeout(timer);
  }, [hls, missingNativeFrameFallback, nativeFrameReady, restartSessionNow, useWebFallback]);

  const onSessionMessage = useCallback(
    (event: WebViewMessageEvent, eventSessionKey: string) => {
      if (eventSessionKey !== activeSessionKeyRef.current) {
        return;
      }
      let payload: any;
      try {
        payload = JSON.parse(event.nativeEvent.data);
      } catch {
        return;
      }
      if (payload?.type === 'twitcastingStream' && typeof payload.hlsUrl === 'string') {
        markSessionResolved();
        setHls({url: payload.hlsUrl, cookieHeader: String(payload.cookies ?? '')});
      } else if (payload?.type === 'twitcastingOffline' || payload?.type === 'twitcastingError') {
        scheduleReconnect();
      }
    },
    [markSessionResolved, scheduleReconnect],
  );
  const renderWebFallback = useWebFallback || missingNativeFrameFallback;

  // streamserver.php は player=pc_web でも Android mobile UA で通るため、WebView と HLS の UA を揃える。
  const sessionWebView =
    !missingNativeFrameFallback ? (
      <WebView
        key={`twitcasting-session:${sessionKey}`}
        source={{uri: `https://twitcasting.tv/${encodeURIComponent(channel)}`}}
        userAgent={mobileUserAgent}
        javaScriptEnabled
        domStorageEnabled
        sharedCookiesEnabled
        thirdPartyCookiesEnabled
        setSupportMultipleWindows={false}
        injectedJavaScript={twitcastingSessionScript(channel)}
        onMessage={event => onSessionMessage(event, sessionKey)}
        onError={scheduleReconnect}
        onHttpError={scheduleReconnect}
        onRenderProcessGone={scheduleReconnect}
        containerStyle={styles.hiddenBridgeWeb}
        style={styles.hiddenBridgeWeb}
      />
    ) : null;

  if (hls && shouldRenderNativeSession(true, renderWebFallback)) {
    return (
      <>
        {sessionWebView}
        <NativeHlsPlayer
          key={`${hls.url}:${reloadKey}:${sessionReloadTick}`}
          style={styles.nativePlayer}
          sourceUrl={hls.url}
          headers={{
            Cookie: hls.cookieHeader,
            'User-Agent': mobileUserAgent,
            Referer: `https://twitcasting.tv/${channel}`,
            Origin: 'https://twitcasting.tv',
          }}
          paused={paused}
          muted={muted}
          volume={volume}
          maxBitrate={playbackQuality === 'economy' ? 900000 : 0}
          resizeMode="contain"
          onPlayerEvent={event => {
            const payload = event.nativeEvent;
            if (payload.type === 'firstFrame') {
              setNativeFrameReady(true);
            }
            if (payload.type === 'error') {
              setMissingNativeFrameFallback(true);
            }
            handlePlayerStatus(payload.type, payload.message, paused);
          }}
        />
        <DanmakuOverlay stream={stream} settings={settings} />
        <GiftOverlay stream={stream} settings={settings} />
      </>
    );
  }

  if (renderWebFallback) {
    return (
      <>
        {sessionWebView}
        <WebView
          key={`twitcasting-web:${channel}:${reloadKey}:${sessionReloadTick}`}
          source={{uri: webStreamURL(stream)}}
          userAgent={mobileUserAgent}
          javaScriptEnabled
          domStorageEnabled
          sharedCookiesEnabled
          thirdPartyCookiesEnabled
          allowsInlineMediaPlayback
          mediaPlaybackRequiresUserAction={false}
          setSupportMultipleWindows={false}
          injectedJavaScript={webFallbackScript(settings.blockWebAds, 'twitcasting')}
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
        <GiftOverlay stream={stream} settings={settings} />
      </>
    );
  }

  return (
    <>
      {sessionWebView}
      <View style={styles.playerPlaceholder}>
        <ActivityIndicator color="#7ab7ff" />
        <Text style={styles.playerStatus}>ツイキャス接続中</Text>
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
  // order を毎レンダー再生成すると下の effect が毎回走るため useMemo で固定する。
  const order = useMemo(() => orderedPlatforms(settings.platformOrder), [settings.platformOrder]);
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
      <SafeAreaView style={styles.modal} edges={appSafeAreaEdges}>
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
  onAuth: AuthCommit;
}) {
  const {width: windowWidth, height: windowHeight} = useWindowDimensions();
  const paneLayout = focusedPaneLayout(windowWidth, windowHeight, settings.showChat);
  const useWideLayout = paneLayout === 'wide';
  const chatRef = useRef<WebView>(null);
  const niconicoCommentRef = useRef<NiconicoCommentSender | null>(null);
  const setNiconicoCommentBridge = useCallback((send: NiconicoCommentSender | null) => {
    niconicoCommentRef.current = send;
  }, []);
  const [commentText, setCommentText] = useState('');
  const [commentStatus, setCommentStatus] = useState('');
  const chat = stream ? chatURL(stream) : null;
  const showFocusChatColumn = paneLayout !== 'solo';
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
      })
      .catch(error => {
        if (!chatRef.current) {
          setCommentStatus(error instanceof Error ? error.message : String(error));
          return;
        }
        injectWebComment(chatRef.current, text);
        setCommentStatus('Webチャット入力を試行しました（未確認）');
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
      <SafeAreaView style={styles.modal} edges={appSafeAreaEdges}>
        {stream && (
          <View style={[styles.focusSurface, useWideLayout && styles.focusSurfaceWide]}>
            {showFocusChatColumn && (
              <View style={[styles.focusChatColumn, useWideLayout && styles.focusChatColumnWide]}>
                <View style={styles.focusChatPanel}>
                  {chat ? (
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
              </View>
            )}
            <View
              style={[
                styles.focusPlayer,
                showFocusChatColumn ? styles.focusPlayerStacked : styles.focusPlayerSolo,
                showFocusChatColumn && useWideLayout && styles.focusPlayerWide,
              ]}
              onTouchStart={showChrome}>
              <StreamPlayer
                stream={stream}
                settings={settings}
                streamCount={streamCount}
                paused={false}
                muted={muted || volume <= 0}
                volume={volume}
                reloadKey={reloadKey}
                onNiconicoCommentBridge={setNiconicoCommentBridge}
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

function SettingsScreen({
  settings,
  onSettings,
  onMovePlatform,
  onClear,
  auth,
  onAuth,
  onLogin,
  pendingDeviceOAuth,
  onResumeDeviceOAuth,
  onCancelDeviceOAuth,
  onNiconicoLogin,
}: {
  settings: AppSettings;
  onSettings: (patch: Partial<AppSettings>) => void;
  onMovePlatform: (index: number, delta: number) => void;
  onClear: () => void;
  auth: AuthState;
  onAuth: AuthCommit;
  onLogin: (service: OAuthService) => void;
  pendingDeviceOAuth: PendingDeviceOAuth | null;
  onResumeDeviceOAuth: (pending: PendingDeviceOAuth) => void;
  onCancelDeviceOAuth: () => void;
  onNiconicoLogin: () => void;
}) {
  const order = orderedPlatforms(settings.platformOrder);

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
      <AuthServicePanel
        service="twitch"
        auth={auth}
        onAuth={onAuth}
        onLogin={onLogin}
        pendingDeviceOAuth={pendingDeviceOAuth?.service === 'twitch' ? pendingDeviceOAuth : null}
        onResumeDeviceOAuth={onResumeDeviceOAuth}
        onCancelDeviceOAuth={onCancelDeviceOAuth}
      />
      <AuthServicePanel service="twitcasting" auth={auth} onAuth={onAuth} onLogin={onLogin} />
      <AuthServicePanel
        service="youtube"
        auth={auth}
        onAuth={onAuth}
        onLogin={onLogin}
        pendingDeviceOAuth={pendingDeviceOAuth?.service === 'youtube' ? pendingDeviceOAuth : null}
        onResumeDeviceOAuth={onResumeDeviceOAuth}
        onCancelDeviceOAuth={onCancelDeviceOAuth}
      />
      <NiconicoLoginPanel onLogin={onNiconicoLogin} />

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
  pendingDeviceOAuth = null,
  onResumeDeviceOAuth,
  onCancelDeviceOAuth,
}: {
  service: OAuthService;
  auth: AuthState;
  onAuth: AuthCommit;
  onLogin: (service: OAuthService) => void;
  pendingDeviceOAuth?: PendingDeviceOAuth | null;
  onResumeDeviceOAuth?: (pending: PendingDeviceOAuth) => void;
  onCancelDeviceOAuth?: () => void;
}) {
  const state = auth[service];
  const label = serviceLabel(service);
  const sessionUsable = hasUsableAuthSession(auth, service);
  const setConfig = (patch: Partial<typeof state.config>) => {
    void onAuth(updateAuthConfig(auth, service, patch), auth, [service]).catch(() => undefined);
  };
  const logout = () => {
    void onAuth(signOut(auth, service), auth, [service]).catch(() => undefined);
  };
  const redirectHelp = service === 'youtube'
    ? 'YouTubeは外部ブラウザのDevice Code認証を使います。Client IDはDevice/TVまたはInstalled app向けを使ってください。'
    : service === 'twitch'
      ? 'Twitchは外部ブラウザのDevice Code認証を使い、access tokenを自動更新します。開発者ポータルでPublicクライアントを使ってください。'
      : 'Redirect URIは開発者ポータルに登録した値と完全一致させてください。';
  return (
    <View style={styles.authPanel}>
      <View style={styles.authHeader}>
        <View>
          <Text style={styles.authTitle}>{label}</Text>
          <Text style={styles.authStatus}>{authStatus(auth, service)}</Text>
        </View>
        <TouchableOpacity
          style={[styles.smallButton, (sessionUsable || pendingDeviceOAuth) && styles.dangerButton]}
          onPress={() => (pendingDeviceOAuth ? onCancelDeviceOAuth?.() : sessionUsable ? logout() : onLogin(service))}>
          <Text style={styles.smallButtonText}>
            {pendingDeviceOAuth ? '認証キャンセル' : sessionUsable ? 'ログアウト' : state.token ? '再ログイン' : 'ログイン'}
          </Text>
        </TouchableOpacity>
      </View>
      {pendingDeviceOAuth && (
        <View style={styles.pendingAuthCard}>
          <Text style={styles.pendingAuthLabel}>外部ブラウザで次のコードを入力してください</Text>
          <Text selectable style={styles.pendingAuthCode}>{pendingDeviceOAuth.userCode}</Text>
          <Text selectable style={styles.pendingAuthURL}>{pendingDeviceOAuth.verificationUrl}</Text>
          <TouchableOpacity
            style={styles.pendingAuthButton}
            onPress={() => onResumeDeviceOAuth?.(pendingDeviceOAuth)}>
            <Text style={styles.smallButtonText}>ブラウザをもう一度開く</Text>
          </TouchableOpacity>
        </View>
      )}
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
      {service !== 'youtube' && service !== 'twitch' && (
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
      <SafeAreaView style={styles.modal} edges={appSafeAreaEdges}>
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
  handoffModeTabs: {
    height: 46,
    marginHorizontal: 16,
    marginTop: 14,
    padding: 3,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: '#263241',
    backgroundColor: '#101720',
    flexDirection: 'row',
  },
  handoffModeButton: {
    flex: 1,
    borderRadius: 6,
    alignItems: 'center',
    justifyContent: 'center',
  },
  handoffModeButtonActive: {
    backgroundColor: '#2f8cff',
  },
  handoffModeText: {
    color: '#9aa7b7',
    fontSize: 14,
    fontWeight: '800',
  },
  handoffModeTextActive: {
    color: '#fff',
  },
  handoffBody: {
    flex: 1,
  },
  handoffContent: {
    paddingTop: 16,
    paddingBottom: 24,
  },
  sectionTitle: {
    color: '#f7f9fc',
    fontSize: 18,
    fontWeight: '700',
    marginBottom: 10,
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
  platformDot: {
    width: 9,
    height: 9,
    borderRadius: 5,
    marginRight: 8,
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
    flex: 0,
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
    bottom: 10,
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
  focusSurfaceWide: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  focusChatColumn: {
    flex: 1,
    minHeight: 0,
  },
  focusChatColumnWide: {
    height: '100%',
    marginRight: 10,
  },
  focusChatPanel: {
    flex: 1,
    minHeight: 100,
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
    backgroundColor: '#000',
    position: 'relative',
  },
  focusPlayerStacked: {
    width: '100%',
    aspectRatio: 16 / 9,
  },
  focusPlayerSolo: {
    flex: 1,
    width: '100%',
    height: '100%',
  },
  focusPlayerWide: {
    width: '58%',
    maxHeight: '100%',
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
  pendingAuthCard: {
    marginTop: 8,
    padding: 10,
    borderRadius: 7,
    borderWidth: 1,
    borderColor: '#2f8cff',
    backgroundColor: '#101b29',
  },
  pendingAuthLabel: {
    color: '#c8d5e6',
    fontSize: 12,
  },
  pendingAuthCode: {
    marginTop: 6,
    color: '#fff',
    fontSize: 22,
    fontWeight: '900',
    letterSpacing: 2,
  },
  pendingAuthURL: {
    marginTop: 4,
    color: '#8ebeff',
    fontSize: 12,
  },
  pendingAuthButton: {
    minHeight: 36,
    marginTop: 8,
    paddingHorizontal: 12,
    alignSelf: 'flex-start',
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 7,
    backgroundColor: '#2f8cff',
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
  handoffQr: {
    width: 240,
    height: 240,
    alignSelf: 'center',
    marginTop: 12,
    borderRadius: 12,
    backgroundColor: '#ffffff',
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
