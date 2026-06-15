# PHASE 2 — プレイヤー安定化

目的: 「プレイヤー/レイアウトが不安定」を根治。ネイティブの状態をJSへ届け、自動復旧・画質制御・背景音声・WebView軽量化を入れる。

---

## 2A. ネイティブ・プレイヤー イベントブリッジ（最優先・他の土台）

### 現状（根拠）
- `NativeHlsPlayerView.emit()` が no-op（NativeHlsPlayerView.kt:182-186）。ExoPlayer の buffering/ready/ended/error が JS に届かない。`onPlayerEvent`（NativeHlsPlayer.tsx）が死んでおり、UIはネイティブの不調を検知できない。

### 目標
- ExoPlayer の `Player.Listener`（`onPlaybackStateChanged`, `onPlayerError`, `onIsPlayingChanged`）を JS イベント（`onPlayerEvent {type, detail}`）として正しく emit（Fabric/bridgeless 対応の event emitter 配線）。
- JS 側 `NativeHlsPlayer` の `onPlayerEvent` を実効化し、上位（StreamPlayer）へ state を伝播。

### タスク
- [ ] 2A.1 `NativeHlsPlayerView` に Player.Listener 実装＋ `emit` を Fabric event 経由で実装。
- [ ] 2A.2 `NativeHlsPlayerManager` の event 登録（`getExportedCustomDirectEventTypeConstants` 等）整備。
- [ ] 2A.3 JS 側で `onPlayerEvent` を受け、`buffering/playing/ended/error` を state 化。

### 受け入れ基準（実機）
- Kick/Twitch を再生し、logcat で JS 側に buffering→ready→playing イベントが届く。
- 配信停止/ネット切断で error イベントが JS に届く。

---

## 2B. 自動復旧（stall watchdog + デバウンス再読込）

### 現状（根拠）
- 復旧ロジック皆無。停止/オフライン時は手動 remove→add のみ（PHASE 1で手動更新は追加するが自動化が必要）。
- iOS: `StallWatchdog`(PlaybackSupport.swift:70, 12s 凍結検出/20s cooldown)、`.multiViewPlaybackErrored` のデバウンス自動更新（45s に1回, ViewingUI.swift:78-86）、native→web 多段フォールバック。

### 目標
- 2A のイベントを使い、error/長時間 buffering を検知したら**デバウンス付き自動リロード**（同一セル 45s に1回上限、iOS準拠）。
- 一定回数ネイティブ失敗で web フォールバックへ降格（iOSの NativeFallbackRetry 相当）。

### タスク
- [ ] 2B.1 セル単位の error/stall 検知＋45sデバウンス自動 reload。
- [ ] 2B.2 連続失敗時の native→web フォールバック降格。
- [ ] 2B.3 復旧ループ防止（cooldown / 回数上限）。

### 受け入れ基準（実機）
- 再生中にネット瞬断→復帰で、手動操作なしに自動再開（logcatで自動reload確認）。
- 復旧ループ（無限リロード）が起きない。

---

## 2C. 画質適応・ビットレート制御

### 現状（根拠）
- `mobileQuality` 未使用、NetInfo 無し（network種別検出なし）。`effectiveQuality`(playback.ts:34-39) は wifiQuality か economy(≥3本)のみ。ExoPlayer のビットレート上限制御無し。「自動エコノミー」はニコ生ラベル変更のみ。
- iOS: `NetworkQuality`(NWPathMonitor) で wifi/cellular 判定→ `activeQuality`、`effectivePeakBitRate`(≥3本で900kbps上限, NetworkQuality.swift:50)、wifi↔cellular 切替で再構築(debounce 4s)。

### 目標
- `@react-native-community/netinfo` 導入し wifi/cellular 検出 → `mobileQuality`/`wifiQuality` を実効化。
- ExoPlayer に最大ビットレート/解像度上限を `DefaultTrackSelector.setParameters(setMaxVideoBitrate / setMaxVideoSize)` で適用。economy=約900kbps（iOS準拠）。
- ≥3本 自動エコノミー（autoEconomyOnManyStreams）を ExoPlayer のビットレート上限へ反映。
- 接続切替(debounce 4s)で品質再適用（再構築 or トラック再選択）。

### タスク
- [ ] 2C.1 NetInfo 導入＋ wifi/cellular → activeQuality 反映。
- [ ] 2C.2 `NativeHlsPlayerView` に maxBitrate/maxSize 設定 prop 追加＋ExoPlayer反映。
- [ ] 2C.3 ≥3本 自動エコノミーをビットレート上限に反映。
- [ ] 2C.4 接続切替の debounce 再適用。

### 受け入れ基準（実機）
- Wi-Fi/モバイルでビットレートが切替（logcatの選択トラックで確認）。
- 3本以上で自動的に低ビットレート選択。

---

## 2D. 背景音声 / AppState 割り込み復帰

### 現状（根拠）
- `AppState` リスナー皆無。background/foreground 制御なし。manifest に foreground service / media session 無し（AndroidManifest.xml は INTERNET と単一Activityのみ）。背景での音声継続が不定。
- iOS: `AVAudioSession`(.playback) 背景音声、割り込み yield→復帰 reload、`PlaybackCoordinator.resumeAll/pauseAll`。

### 目標
- **背景音声再生**: foreground service（`foregroundServiceType="mediaPlayback"`）＋ MediaSession（ExoPlayer `MediaSessionService` or `media3`）。manifest 権限追加。
- RN `AppState` 監視: background→既定で再生継続（音声）、foreground 復帰で resume/必要なら reload。他アプリ音声割り込み時の挙動を整える。
- 複数音声の扱い（iOSは各セル個別音量、同時出力可）を踏襲しつつ、必要なら「フォーカス時のみ全音量」等の調整。

### タスク
- [ ] 2D.1 manifest: foregroundService 権限＋service 宣言。
- [ ] 2D.2 media3 MediaSession/Service 導入（背景音声継続）。
- [ ] 2D.3 RN AppState ハンドラ（background/active）で resume/reload。

### 受け入れ基準（実機）
- アプリを背景化しても音声が継続（少なくとも1本）。
- 復帰時に映像が再開（必要時 reload）。
- 他アプリ動画再生→復帰で自アプリが正しく復帰。

---

## 2E. YouTube WebView 軽量化

### 現状（根拠）
- YouTube 1配信で最大3 WebView（iframe player + 隠し視聴者数スクレイプ + 隠し公式チャットbridge, App.tsx:1130-1144 / YouTubeOfficialChatBridge.tsx）。多配信で重く不安定。

### 目標
- 視聴者数は可能な限り InnerTube API（fetch）に集約し、隠しWebViewを削減。
- 公式チャットbridge は HLSネイティブ再生時には不要化、または1本に統合。
- iframe フォールバック時のみ必要最小限の WebView に。

### タスク
- [ ] 2E.1 視聴者数 fetch 経路を整理し隠しWebViewを削除/条件化。
- [ ] 2E.2 チャットbridge の起動条件を最小化。

### 受け入れ基準（実機）
- YouTube を複数本表示してもメモリ/CPUが許容内（logcat/Profiler）。
- 視聴者数・弾幕は維持。

---

## 実行体制
- 2A→2B は依存関係があるため順次。2A はネイティブ(Kotlin)実装、サブエージェント or codex 主体。
- 2C/2D はネイティブ依存が強く codex/サブエージェントに委譲、本体が実機検証。
- 各サブフェーズ完了ごとに `/codex:review`。
