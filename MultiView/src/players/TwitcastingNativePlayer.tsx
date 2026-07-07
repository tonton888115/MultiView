import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {ActivityIndicator, AppState, Text, View} from 'react-native';
import {WebView, type WebViewMessageEvent} from 'react-native-webview';
import {DanmakuOverlay} from '../DanmakuOverlay';
import {GiftOverlay} from '../GiftOverlay';
import {NativeHlsPlayer} from '../NativeHlsPlayer';
import {effectiveQuality, mobileUserAgent, webStreamURL} from '../playback';
import type {AppSettings, StreamItem} from '../types';
import {isAdBlockedURL} from '../adblock';
import {webFallbackScript} from '../webInject';
import {twitcastingSessionScript} from '../twitcasting';
import {useNetworkType} from '../network';
import {useRecoveringNativeSession} from '../useRecoveringNativeSession';
import {nativeFirstFrameTimeoutMs, shouldFallbackForMissingNativeFrame, shouldRenderNativeSession, shouldRestartSessionOnAppState} from '../sessionRecovery';
import {sharedStyles} from '../components/sharedStyles';

export const TwitcastingNativePlayer = React.memo(function TwitcastingNativePlayer({
  viewingActive = true,
  stream,
  settings,
  streamCount,
  paused,
  muted,
  volume,
  reloadKey,
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

  // 注入スクリプト文字列とインラインハンドラのレンダー毎再生成を止める(memo対応)。
  const sessionInjectionScript = useMemo(() => twitcastingSessionScript(channel), [channel]);
  const handleSessionMessage = useCallback(
    (event: WebViewMessageEvent) => onSessionMessage(event, sessionKey),
    [onSessionMessage, sessionKey],
  );
  const blockWebAds = settings.blockWebAds;
  const fallbackInjectionScript = useMemo(() => webFallbackScript(blockWebAds, 'twitcasting'), [blockWebAds]);
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
      if (payload.type === 'error') {
        setMissingNativeFrameFallback(true);
      }
      handlePlayerStatus(payload.type, payload.message, paused);
    },
    [handlePlayerStatus, paused],
  );

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
        injectedJavaScript={sessionInjectionScript}
        onMessage={handleSessionMessage}
        onError={scheduleReconnect}
        onHttpError={scheduleReconnect}
        onRenderProcessGone={scheduleReconnect}
        containerStyle={sharedStyles.hiddenBridgeWeb}
        style={sharedStyles.hiddenBridgeWeb}
      />
    ) : null;

  if (hls && shouldRenderNativeSession(true, renderWebFallback)) {
    return (
      <>
        {sessionWebView}
        <NativeHlsPlayer
          key={`${hls.url}:${reloadKey}:${sessionReloadTick}`}
          style={sharedStyles.nativePlayer}
          sourceUrl={hls.url}
          headers={{
            Cookie: hls.cookieHeader,
            'User-Agent': mobileUserAgent,
            Referer: `https://twitcasting.tv/${channel}`,
            Origin: 'https://twitcasting.tv',
          }}
          paused={paused}
          viewingActive={viewingActive}
          muted={muted}
          volume={volume}
          maxBitrate={playbackQuality === 'economy' ? 900000 : 0}
          resizeMode="contain"
          onPlayerEvent={handleNativePlayerEvent}
        />
        <DanmakuOverlay stream={stream} settings={settings} active={viewingActive} />
        <GiftOverlay stream={stream} settings={settings} active={viewingActive} />
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
        <Text style={sharedStyles.playerStatus}>ツイキャス接続中</Text>
      </View>
    </>
  );
});
