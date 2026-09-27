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
import {isNetworkKnownOffline, onNetworkRestored, useQualityNetworkType} from '../network';
import {autoReloadBackoffMs, nativeSourceRecoveryDelayForAttempt, networkRestoreGraceMs, nextAutoReloadAttempt, shouldRecoverNativeSource, shouldReloadCellOnViewActivation, shouldReloadOnViewActivation, youtubeUpgradeDelayForAttempt} from '../sessionRecovery';
import type {PlayerHealth} from '../sessionRecovery';
import {PlayerBadge} from '../components/PlayerBadge';
import {sharedStyles} from '../components/sharedStyles';
import {NiconicoNativePlayer} from './NiconicoNativePlayer';
import {TwitcastingNativePlayer} from './TwitcastingNativePlayer';

// ニコ生/ツイキャスはネイティブ視聴セッション(useRecoveringNativeSession)が自前で復旧する。
function ownsNativeSession(platform: StreamItem['platform']): boolean {
  return platform === 'niconico' || platform === 'twitcasting';
}

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
  // 自動復旧で同じURLを取り直した場合もネイティブプレイヤーを確実に作り直すための世代。
  const [playerEpoch, setPlayerEpoch] = useState(0);
  const webRef = useRef<WebView>(null);
  // ネイティブプレイヤーの直近イベントから見た健全性。タブ復帰時に「健全なセルは
  // 再マウントしない」判定にだけ使うので、stateではなくref(再レンダー不要)。
  const playerHealthRef = useRef<PlayerHealth>('unknown');
  const streamRef = useRef(stream);
  const settingsRef = useRef(settings);
  const streamCountRef = useRef(streamCount);
  const sourceRef = useRef<PlaybackSource | null>(null);
  // 画質用の回線種別はオフライン中も直前の値を保つ(瞬断で画質が揺れない)。
  const networkType = useQualityNetworkType();
  const playbackQuality = effectiveQuality(settings, streamCount, networkType);
  streamRef.current = stream;
  settingsRef.current = settings;
  streamCountRef.current = streamCount;
  sourceRef.current = source;
  // ネイティブプレイヤーの error/ended/idle(停止・ストール含む)を受けての自動復旧。
  // 初回は即、連続失敗はバックオフ。障害イベントは捨てず、予約済みでなければ必ず実行する
  // (致命的エラー後のネイティブはイベントを出さないため、捨てると永久凍結する)。
  const [autoReloadTick, setAutoReloadTick] = useState(0);
  const autoReloadAttemptRef = useRef(0);
  const lastAutoReloadRef = useRef(0);
  const autoReloadTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // 回線断中に壊れたセル。再取得は必ず失敗して試行回数だけ消費するので、回線復帰まで待つ。
  const waitingForNetworkRef = useRef(false);
  // 直近の障害がエラー無しの停止(stall)か。プレイヤーは生きているので回線復帰後に自力で
  // 再開する余地がある。
  const lastFailureWasStallRef = useRef(false);
  const restoreGraceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const previouslyViewingActiveRef = useRef(viewingActive);
  // 手動更新/配信切替と自動復旧の解決が並走したとき、古い方の結果で新しいプレイヤーを
  // 上書きしないための世代。最新の解決だけが setSource できる。
  const resolveGenerationRef = useRef(0);
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
    if (restoreGraceTimerRef.current) {
      clearTimeout(restoreGraceTimerRef.current);
      restoreGraceTimerRef.current = null;
    }
  }, []);
  const fireAutoReload = useCallback(() => {
    clearAutoReloadTimer();
    waitingForNetworkRef.current = false;
    lastAutoReloadRef.current = Date.now();
    setAutoReloadTick(tick => tick + 1);
  }, [clearAutoReloadTimer]);
  const scheduleAutoReload = useCallback(() => {
    if (autoReloadTimerRef.current || waitingForNetworkRef.current) {
      return;
    }
    if (isNetworkKnownOffline()) {
      waitingForNetworkRef.current = true;
      return;
    }
    const attempt = nextAutoReloadAttempt(autoReloadAttemptRef.current, Date.now(), lastAutoReloadRef.current);
    autoReloadAttemptRef.current = attempt + 1;
    autoReloadTimerRef.current = setTimeout(() => {
      autoReloadTimerRef.current = null;
      fireAutoReload();
    }, autoReloadBackoffMs(attempt));
  }, [fireAutoReload]);

  useEffect(() => clearAutoReloadTimer, [clearAutoReloadTimer]);

  // 回線復帰: 壊れている/ネイティブ再生できていないセルはバックオフを待たず即再接続する。
  useEffect(() => {
    if (ownsNativeSession(stream.platform)) {
      return;
    }
    return onNetworkRestored(() => {
      const kind = sourceRef.current?.kind ?? null;
      if (!waitingForNetworkRef.current && playerHealthRef.current !== 'broken' && kind === 'native') {
        return;
      }
      autoReloadAttemptRef.current = 0;
      nativeRecoveryAttemptRef.current = 0;
      youtubeRetryRef.current = 0;
      if (kind === 'native' && lastFailureWasStallRef.current) {
        // まだ生きているプレイヤーに自力再開の猶予を与える(再生が戻れば作り直さない)。
        // 回線断を検知する前に予約された作り直しがあれば、猶予を優先して取り消す。
        if (autoReloadTimerRef.current) {
          clearTimeout(autoReloadTimerRef.current);
          autoReloadTimerRef.current = null;
        }
        if (!restoreGraceTimerRef.current) {
          restoreGraceTimerRef.current = setTimeout(() => {
            restoreGraceTimerRef.current = null;
            if (playerHealthRef.current !== 'healthy') {
              fireAutoReload();
            } else {
              waitingForNetworkRef.current = false;
            }
          }, networkRestoreGraceMs);
        }
        return;
      }
      fireAutoReload();
    });
  }, [fireAutoReload, stream.platform]);

  useEffect(() => {
    const previouslyActive = previouslyViewingActiveRef.current;
    previouslyViewingActiveRef.current = viewingActive;
    if (ownsNativeSession(streamRef.current.platform)) {
      // ニコ生/ツイキャスは surface 再バインド+自前の復旧で継続できる。タブを戻るたびに
      // 視聴セッションを作り直す(黒画面+再接続)必要はない。
      return;
    }
    if (shouldReloadOnViewActivation(previouslyActive, viewingActive)) {
      // The viewing panel remains mounted beneath other tabs. Android may
      // detach a TextureView or fail a hidden HLS session while it is opaque.
      // ただし直近イベントが健全なネイティブ再生は surface 再バインドで継続する
      // ため再マウントせず、健全と確認できないセルだけ再読込する(iOSのresumeAll
      // が継続再生なのと同じ体験に寄せる)。
      if (shouldReloadCellOnViewActivation(sourceRef.current?.kind ?? null, playerHealthRef.current)) {
        fireAutoReload();
      }
    }
  }, [fireAutoReload, viewingActive]);

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
        lastFailureWasStallRef.current = payload.type === 'error' && payload.message === 'stall';
        scheduleAutoReload();
      } else if (payload.type === 'firstFrame' || payload.message === 'playing') {
        // 'ready'(STATE_READY)は映像を一度も描画していなくても発火するため健全の根拠に
        // しない(READYのまま固まったセルがタブ復帰リロードを免れる)。実描画(firstFrame)
        // か再生進行(playing。音声のみ配信もここを通る)だけを健全とみなす。
        playerHealthRef.current = 'healthy';
        if (lastFailureWasStallRef.current) {
          // 停止(stall)後にプレイヤーが自力で再開した。予約済みの作り直しは不要。
          lastFailureWasStallRef.current = false;
          waitingForNetworkRef.current = false;
          clearAutoReloadTimer();
        }
      }
    },
    [clearAutoReloadTimer, scheduleAutoReload],
  );

  // 配信切替/手動更新: 取得中表示に戻して解決し直す。
  useEffect(() => {
    const currentStream = streamRef.current;
    if (ownsNativeSession(currentStream.platform)) {
      return;
    }
    let cancelled = false;
    // 予約済みの自動復旧はこの解決で置き換わる(後から古い解決で差し戻さない)。
    clearAutoReloadTimer();
    waitingForNetworkRef.current = false;
    const generation = ++resolveGenerationRef.current;
    setSource(null);
    playerHealthRef.current = 'unknown';
    // resolvePlaybackSource は内部で全例外を error ソースへ畳み込み、reject しない
    // (YouTube を Web ページへ落とさないガードも playback.ts 側にある)。
    resolvePlaybackSource(currentStream, settingsRef.current, streamCountRef.current)
      .then(next => {
        if (!cancelled && generation === resolveGenerationRef.current) {
          setSource(next);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [
    clearAutoReloadTimer,
    stream.id,
    stream.platform,
    stream.channel,
    settings.youtubePreferIframe,
    settings.youtubeStableBuffer,
    reloadKey,
  ]);

  // 自動復旧: 取得中表示へは戻さず、今の映像(停止フレーム)と弾幕を出したまま裏で解決し直し、
  // 取れたら差し替える。以前は source=null で弾幕オーバーレイごと外れ、復旧のたびに
  // コメント接続が切れて貼り直し+スピナー表示になっていた。
  useEffect(() => {
    if (autoReloadTick === 0 || ownsNativeSession(streamRef.current.platform)) {
      return;
    }
    let cancelled = false;
    const generation = ++resolveGenerationRef.current;
    playerHealthRef.current = 'unknown';
    resolvePlaybackSource(streamRef.current, settingsRef.current, streamCountRef.current)
      .then(next => {
        if (!cancelled && generation === resolveGenerationRef.current) {
          setSource(next);
          setPlayerEpoch(epoch => epoch + 1);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [autoReloadTick]);

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
      if (isNetworkKnownOffline()) {
        // 回線断中は叩かない(回線復帰時に onNetworkRestored が即再解決する)。
        setYoutubeUpgradeTick(tick => tick + 1);
        return;
      }
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
      if (isNetworkKnownOffline()) {
        // 回線断中は試行回数を消費しない(回線復帰時に onNetworkRestored が即再解決する)。
        setNativeRecoveryTick(tick => tick + 1);
        return;
      }
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
        reloadKey={reloadKey}
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
        reloadKey={reloadKey}
        onViewerCount={onViewerCount}
      />
    );
  }

  let content: React.ReactNode;
  if (!source) {
    content = (
      <View style={sharedStyles.playerPlaceholder}>
        <ActivityIndicator color="#7ab7ff" />
        <Text style={sharedStyles.playerStatus}>取得中</Text>
      </View>
    );
  } else if (source.kind === 'native') {
    content = (
      <NativeHlsPlayer
        key={`${source.url}:${reloadKey}:${playerEpoch}`}
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
    );
  } else if (source.kind === 'youtube-iframe') {
    content = (
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
    );
  } else if (source.kind === 'web' || (source.kind === 'error' && source.fallbackUrl)) {
    const url = source.kind === 'web' ? source.url : source.fallbackUrl ?? 'about:blank';
    content = (
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
        {source.kind === 'error' && <PlayerBadge source={source} status={source.reason} warning />}
      </>
    );
  } else {
    content = (
      <View style={sharedStyles.playerPlaceholder}>
        <Text style={sharedStyles.playerStatus}>{source.reason}</Text>
      </View>
    );
  }

  // 弾幕/ギフトは映像ソースの種類(取得中・ネイティブ・Web・エラー)が変わっても外さない。
  // 復旧のたびにコメント接続を切って貼り直すと、その間のコメントが抜けて不安定に見える。
  return (
    <>
      {content}
      <DanmakuOverlay stream={stream} settings={settings} active={viewingActive} />
      <GiftOverlay stream={stream} settings={settings} active={viewingActive} />
    </>
  );
});
