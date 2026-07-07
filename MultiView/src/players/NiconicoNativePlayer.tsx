import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {ActivityIndicator, AppState, Text, View} from 'react-native';
import {WebView, type WebViewMessageEvent} from 'react-native-webview';
import {DanmakuOverlay} from '../DanmakuOverlay';
import {GiftOverlay} from '../GiftOverlay';
import {NativeHlsPlayer} from '../NativeHlsPlayer';
import {desktopUserAgent, effectiveQuality, mobileUserAgent, webStreamURL} from '../playback';
import type {AppSettings, NiconicoCommentSender, StreamItem} from '../types';
import {isAdBlockedURL} from '../adblock';
import {webFallbackScript} from '../webInject';
import {niconicoOriginURL, niconicoPostCommentScript, niconicoQuality, niconicoSessionScript, niconicoSupportPresentation} from '../niconico';
import {pushNiconicoComment} from '../niconicoComments';
import {publishGiftEvent} from '../giftEvents';
import {useNetworkType} from '../network';
import {useRecoveringNativeSession} from '../useRecoveringNativeSession';
import {nativeFirstFrameTimeoutMs, shouldFallbackForMissingNativeFrame, shouldRenderNativeSession, shouldRestartSessionOnAppState} from '../sessionRecovery';
import {sharedStyles} from '../components/sharedStyles';

export const NiconicoNativePlayer = React.memo(function NiconicoNativePlayer({
  viewingActive = true,
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
  viewingActive?: boolean;
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

  // 注入スクリプト文字列とインラインハンドラのレンダー毎再生成を止める(memo対応)。
  const sessionInjectionScript = useMemo(
    () => niconicoSessionScript(stream.channel, niconicoQuality(playbackQuality)),
    [playbackQuality, stream.channel],
  );
  const handleSessionMessage = useCallback(
    (event: WebViewMessageEvent) => onSessionMessage(event, sessionKey),
    [onSessionMessage, sessionKey],
  );
  const blockWebAds = settings.blockWebAds;
  const fallbackInjectionScript = useMemo(() => webFallbackScript(blockWebAds, 'niconico'), [blockWebAds]);
  const handleShouldStartLoad = useCallback(
    (request: {url?: string}) => !(blockWebAds && isAdBlockedURL(request.url)),
    [blockWebAds],
  );
  const handleFallbackMessage = useCallback(
    (event: WebViewMessageEvent) => {
      try {
        const payload = JSON.parse(event.nativeEvent.data);
        const count = Number(payload?.count);
        if (payload?.type === 'viewerCount' && Number.isFinite(count) && count >= 0) {
          onViewerCount?.(Math.round(count));
        }
      } catch {
        // ignore bridge noise
      }
    },
    [onViewerCount],
  );
  const handleNativePlayerEvent = useCallback(
    (event: {nativeEvent: {type: string; message: string}}) => {
      const payload = event.nativeEvent;
      if (payload.type === 'firstFrame') {
        setNativeFrameReady(true);
      }
      if (payload.type === 'error' || payload.message === 'ended') {
        setHls(null);
      }
      handlePlayerStatus(payload.type, payload.message, paused);
    },
    [handlePlayerStatus, paused],
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
        injectedJavaScript={sessionInjectionScript}
        onMessage={handleSessionMessage}
        onError={scheduleReconnect}
        onHttpError={scheduleReconnect}
        onRenderProcessGone={scheduleReconnect}
        containerStyle={sharedStyles.hiddenBridgeWeb}
        style={sharedStyles.hiddenBridgeWeb}
      />
    ) : null;

  if (sessionEndedMessage) {
    return (
      <View style={sharedStyles.playerPlaceholder}>
        <Text style={sharedStyles.playerStatus}>{sessionEndedMessage}</Text>
      </View>
    );
  }

  if (hls && hls.sessionKey === sessionKey && shouldRenderNativeSession(true, shouldUseOfficialWebFallback)) {
    return (
      <>
        {sessionWebView}
        <NativeHlsPlayer
          key={`${hls.url}:${reloadKey}:${sessionReloadTick}`}
          style={sharedStyles.nativePlayer}
          sourceUrl={hls.url}
          headers={{
            ...(hls.cookieHeader ? {Cookie: hls.cookieHeader} : {}),
            'User-Agent': mobileUserAgent,
            Referer: webStreamURL(stream),
            Origin: 'https://live.nicovideo.jp',
            'Accept-Language': 'ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6',
          }}
          paused={paused}
          viewingActive={viewingActive}
          muted={muted}
          volume={volume}
          liveTargetOffsetMs={settings.niconicoLowLatency ? 2000 : 6000}
          maxBitrate={playbackQuality === 'economy' ? 900000 : 0}
          resizeMode="contain"
          onPlayerEvent={handleNativePlayerEvent}
        />
        <DanmakuOverlay stream={stream} settings={settings} active={viewingActive} />
        <GiftOverlay stream={stream} settings={settings} active={viewingActive} />
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
          injectedJavaScript={fallbackInjectionScript}
          onShouldStartLoadWithRequest={handleShouldStartLoad}
          onMessage={handleFallbackMessage}
          style={sharedStyles.webPlayer}
        />
        <DanmakuOverlay stream={stream} settings={settings} active={viewingActive} />
        <GiftOverlay stream={stream} settings={settings} active={viewingActive} />
      </>
    );
  }

  return (
    <>
      {sessionWebView}
      <View style={sharedStyles.playerPlaceholder}>
        <ActivityIndicator color="#7ab7ff" />
        <Text style={sharedStyles.playerStatus}>ニコ生接続中</Text>
      </View>
    </>
  );
});
