import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {ActivityIndicator, Text, View} from 'react-native';
import {WebView, type WebViewMessageEvent} from 'react-native-webview';
import {DanmakuOverlay} from '../DanmakuOverlay';
import {GiftOverlay} from '../GiftOverlay';
import {NativeHlsPlayer} from '../NativeHlsPlayer';
import {effectiveQuality, mobileUserAgent, resolvePlaybackSource, youtubeIframeHTML} from '../playback';
import type {AppSettings, NiconicoCommentSender, PlaybackSource, StreamItem} from '../types';
import {isAdBlockedURL} from '../adblock';
import {injectWebComment, webFallbackScript} from '../webInject';
import {useNetworkType} from '../network';
import {autoReloadDelayMs, nativeSourceRecoveryDelayForAttempt, shouldRecoverNativeSource, shouldReloadCellOnViewActivation, shouldReloadOnViewActivation, youtubeUpgradeDelayForAttempt} from '../sessionRecovery';
import type {PlayerHealth} from '../sessionRecovery';
import {PlayerBadge} from '../components/PlayerBadge';
import {sharedStyles} from '../components/sharedStyles';
import {NiconicoNativePlayer} from './NiconicoNativePlayer';
import {TwitcastingNativePlayer} from './TwitcastingNativePlayer';

// React.memo: source 解決やネイティブイベントで頻繁に再レンダーする階層の起点。
// props(ハンドラ含む)は呼び出し側で安定化済み。
export const StreamPlayer = React.memo(function StreamPlayer({
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
  const webRef = useRef<WebView>(null);
  // ネイティブプレイヤーの直近イベントから見た健全性。タブ復帰時に「健全なセルは
  // 再マウントしない」判定にだけ使うので、stateではなくref(再レンダー不要)。
  const playerHealthRef = useRef<PlayerHealth>('unknown');
  const streamRef = useRef(stream);
  const settingsRef = useRef(settings);
  const streamCountRef = useRef(streamCount);
  const sourceRef = useRef<PlaybackSource | null>(null);
  const networkType = useNetworkType();
  const playbackQuality = effectiveQuality(settings, streamCount, networkType);
  streamRef.current = stream;
  settingsRef.current = settings;
  streamCountRef.current = streamCount;
  sourceRef.current = source;
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
  const nativeRecoveryAttemptRef = useRef(0);
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
      // ただし直近イベントが健全なネイティブ再生は surface 再バインドで継続する
      // ため再マウントせず、健全と確認できないセルだけ再読込する(iOSのresumeAll
      // が継続再生なのと同じ体験に寄せる)。
      if (shouldReloadCellOnViewActivation(sourceRef.current?.kind ?? null, playerHealthRef.current)) {
        clearAutoReloadTimer();
        lastAutoReloadRef.current = Date.now();
        setAutoReloadTick(tick => tick + 1);
      }
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

  // ~6KB の注入スクリプト文字列をレンダー毎に再構築しない。入力が変わった時だけ作る。
  const blockWebAds = settings.blockWebAds;
  const fallbackInjectionScript = useMemo(
    () => webFallbackScript(blockWebAds, stream.platform),
    [blockWebAds, stream.platform],
  );
  const handleShouldStartLoad = useCallback(
    (request: {url?: string}) => !(blockWebAds && isAdBlockedURL(request.url)),
    [blockWebAds],
  );
  const handleNativePlayerEvent = useCallback(
    (event: {nativeEvent: {type: string; message: string}}) => {
      const payload = event.nativeEvent;
      // 'idle' は致命的エラー後の停止状態。error イベントが失われても復旧に繋ぐ。
      if (payload.type === 'error' || payload.message === 'ended' || payload.message === 'idle') {
        playerHealthRef.current = 'broken';
        scheduleAutoReload();
      } else if (payload.message === 'playing' || payload.message === 'ready') {
        playerHealthRef.current = 'healthy';
      }
    },
    [scheduleAutoReload],
  );

  useEffect(() => {
    const currentStream = streamRef.current;
    if (currentStream.platform === 'niconico' || currentStream.platform === 'twitcasting') {
      // ニコ生/ツイキャスはネイティブ視聴セッションが自前で扱う。
      return;
    }
    let cancelled = false;
    setSource(null);
    playerHealthRef.current = 'unknown';
    // resolvePlaybackSource は内部で全例外を error ソースへ畳み込み、reject しない
    // (YouTube を Web ページへ落とさないガードも playback.ts 側にある)。
    resolvePlaybackSource(currentStream, settingsRef.current, streamCountRef.current)
      .then(next => {
        if (!cancelled) {
          setSource(next);
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
    if (settings.youtubePreferIframe) {
      // iframe優先設定では resolve が常に iframe を返すため、この昇格再解決は
      // 絶対に成功しない(=@handleならライブページHTML全取得を無限に繰り返すだけ)。
      // ループ自体を止める。
      youtubeRetryRef.current = 0;
      return;
    }
    // Web ページへは絶対に落とさず、映像のみ(native HLS)が取れるまで粘る。
    // 初回数回は素早く、以降は間隔を空けて再解決し続ける(YouTube への負荷も抑える)。
    const delay = youtubeUpgradeDelayForAttempt(youtubeRetryRef.current);
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
  }, [source, stream.platform, settings.youtubePreferIframe, youtubeUpgradeTick]);

  // Twitch/Kick は再解決失敗やオフライン判定でエラー/Webフォールバックへ落ちると、
  // 回線復帰後も native HLS へ戻る経路が無かった(iOS は StallWatchdog+再取得ラダー
  // が再接続する)。YouTube と同じく静かに再解決し、native が取れたときだけ差し替える。
  useEffect(() => {
    if (!source || !shouldRecoverNativeSource(stream.platform, source.kind)) {
      nativeRecoveryAttemptRef.current = 0;
      return;
    }
    let cancelled = false;
    // オフライン配信を固定間隔で無期限ポーリングしない。失敗が続くほど間隔を
    // 倍々で広げる(上限5分)。native復帰か配信切替でattemptは0に戻る。
    const timer = setTimeout(async () => {
      try {
        const next = await resolvePlaybackSource(streamRef.current, settingsRef.current, streamCountRef.current);
        if (cancelled) {
          return;
        }
        if (next.kind === 'native') {
          nativeRecoveryAttemptRef.current = 0;
          setSource(next);
        } else {
          nativeRecoveryAttemptRef.current += 1;
          setNativeRecoveryTick(tick => tick + 1);
        }
      } catch {
        if (!cancelled) {
          nativeRecoveryAttemptRef.current += 1;
          setNativeRecoveryTick(tick => tick + 1);
        }
      }
    }, nativeSourceRecoveryDelayForAttempt(nativeRecoveryAttemptRef.current));
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
        viewingActive={viewingActive}
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
        viewingActive={viewingActive}
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
      <View style={sharedStyles.playerPlaceholder}>
        <ActivityIndicator color="#7ab7ff" />
        <Text style={sharedStyles.playerStatus}>取得中</Text>
      </View>
    );
  }

  if (source.kind === 'native') {
    return (
      <>
        <NativeHlsPlayer
          key={`${source.url}:${reloadKey}:${autoReloadTick}`}
          style={sharedStyles.nativePlayer}
          sourceUrl={source.url}
          headers={source.headers}
          paused={paused}
          viewingActive={viewingActive}
          muted={muted}
          volume={volume}
          liveTargetOffsetMs={source.liveTargetOffsetMs}
          maxBitrate={playbackQuality === 'economy' ? 900000 : 0}
          resizeMode="contain"
          onPlayerEvent={handleNativePlayerEvent}
        />
        <DanmakuOverlay stream={stream} settings={settings} active={viewingActive} />
        <GiftOverlay stream={stream} settings={settings} active={viewingActive} />
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
          style={sharedStyles.webPlayer}
        />
        <DanmakuOverlay stream={stream} settings={settings} active={viewingActive} />
        <GiftOverlay stream={stream} settings={settings} active={viewingActive} />
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
          injectedJavaScript={fallbackInjectionScript}
          onShouldStartLoadWithRequest={handleShouldStartLoad}
          onMessage={handleWebMessage}
          style={sharedStyles.webPlayer}
        />
        <DanmakuOverlay stream={stream} settings={settings} active={viewingActive} />
        <GiftOverlay stream={stream} settings={settings} active={viewingActive} />
        {source.kind === 'error' && <PlayerBadge source={source} status={source.reason} warning />}
      </>
    );
  }

  return (
    <View style={sharedStyles.playerPlaceholder}>
      <Text style={sharedStyles.playerStatus}>{source.reason}</Text>
    </View>
  );
});
