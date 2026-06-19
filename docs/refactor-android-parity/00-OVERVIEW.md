# MultiView Android パリティ・リファクタリング — 全体設計とゴール

最終更新: 2026-06-15 / 起点コミット: `a836a38`

## 0. 結論（アーキテクチャの実態）

| 項目 | iOS | Android |
|---|---|---|
| 技術スタック | **完全ネイティブ UIKit/Swift**（約14,300行 / 30ファイル） | **React Native**（App.tsx 3,514行 + src ≈3,500行 + 薄いKotlin HLSモジュール） |
| プレイヤー | ネイティブ AVPlayer / Amazon IVS / WebSocket protocol client | ExoPlayer(HLS) + react-native-webview + iframe |
| 共有Web資産 | `docs/player.html`/`chat.html` は **フォールバック専用** | これらは **使っていない**（App.tsx内のロジックで自前描画） |

iOSとAndroidは**別実装**。ゆえに「iOSの機能がAndroidにない／広告が出る／不安定」は当然の帰結。本リファクタは **iOSをリファレンス仕様としてAndroid(RN)を機能パリティへ引き上げる**。

## 1. ユーザーの訴え → 原因（実コード根拠）

1. **広告が出る** → Androidに実効的な広告ブロックが無い。`blockWebAds`(既定ON)は `webFallbackScript`(App.tsx:2654-2670)のDOM非表示だけで、ネットワーク/プリロール/ニコ生広告は素通り。iOSの `WebAdBlocker`(WKContentRuleList)、niconicoポップアップブロッカー、埋め込みプレイヤーtouch shieldに相当する仕組みがAndroidに無い。ニコ生は常にフルWebページ(playback.ts:315-324)で最悪。
2. **更新ボタンが無い** → 配線は存在するが死んでいる。`reloadKey`は全箇所で`0`にハードコード（App.tsx:745,793,2012）、`sendNativePlayerCommand('reload')`(NativeHlsPlayer.tsx:34-43)はどこからも呼ばれていない。グローバル更新もセル別更新もUIに存在しない。停止/オフライン時の復旧手段が「削除→再追加」しかない。
3. **プレイヤー/レイアウトが不安定** →
   - グリッド偶数バグ: `gridSlots`(App.tsx:808-814)。`bigCount = 偶数?2:1` で末尾セルが全幅化し、偶数だと2列タイルにならない（ロジックが実質反転）。iOSの `addGrid`(ViewingUI.swift:312)が正仕様。
   - ネイティブプレイヤーのエラー/バッファがJSに届かない: `NativeHlsPlayerView.emit()`(NativeHlsPlayerView.kt:182-186)がno-op。`onPlayerEvent`が死に、自動復旧不能。
   - YouTube 1配信あたり最大3 WebView（iframe + 視聴者数スクレイプ + 公式チャットbridge）で重い。
4. **機能欠落（iOSにあってAndroidに無い／死んでいる）** →
   - レイド自動追加: `autoFollowRaids` はトグルのみ、実装ゼロ（grep確認）。
   - ニコ生: ネイティブプレイヤー無し（WebのみでHLS未移植）、弾幕も無し（chat.ts:48-49が空クライアント返却）。
   - 背景音声 / AppStateハンドリング無し（manifestにforeground service/media session無し）。割り込み・復帰時の制御無し。
   - 画質: `mobileQuality`は一度も読まれない。NetInfo無しでネットワーク種別検出無し。ExoPlayerのビットレート上限制御無し。「自動エコノミー」はニコ生ラベル変更のみで実効ほぼ無し。
   - 死にトグル: `niconicoLowLatency` / `showGiftEffects` / `giftSoundEnabled` / `niconicoShowGift` / `niconicoShowNicoad` / `niconicoShowNotification` はUIだけで挙動無し。

## 2. 機能パリティ・マトリクス（iOS基準）

凡例: ✅実装 / 🟡部分・不安定 / ❌欠落・死にコード

| 機能領域 | iOS | Android 現状 | 目標 |
|---|---|---|---|
| 4タブ構成(フォロー/ランキング/視聴/設定) | ✅ | ✅ | 維持 |
| 設定画面の項目網羅 | ✅ | 🟡(UIはあるが死にトグル多数) | 全トグルを実効化 |
| グリッド/スタック レイアウト | ✅ | 🟡(偶数グリッドバグ) | iOS同等のタイル規則 |
| フォーカス(単独拡大)表示 | ✅ | ✅(FocusModal) | 維持・安定化 |
| 自動非表示コントロール | ✅(2.4s) | ✅(2400ms) | 維持 |
| **グローバル更新ボタン** | ✅(ViewingUI.swift:270) | ❌ | 実装 |
| セル別の自動復旧 | ✅(stall watchdog+debounced reload) | ❌(emit no-op) | 実装 |
| **手動更新(セル別)** | ✕(iOSは自動のみ) | ❌ | 追加実装(Android独自に有用) |
| Kick/Twitch/TwitCasting ネイティブHLS | ✅ | ✅(ExoPlayer) | 安定化 |
| YouTube ネイティブHLS+iframeフォールバック | ✅ | 🟡(3 WebViewで重い) | 軽量化・安定化 |
| **ニコ生 ネイティブ再生** | ✅(WS+NDGR) | ❌(Webのみ) | 段階移植 or Web+広告ブロック |
| **広告ブロック(ネットワーク級)** | ✅(WKContentRuleList) | ❌(DOM隠しのみ) | 実装 |
| niconicoポップアップ/埋め込みtouch shield | ✅ | ❌ | 実装 |
| 同接数表示(5プラットフォーム) | ✅(30s) | ✅(30s) | 維持・軽量化 |
| **レイド自動追加** | ✅(イベント駆動) | ❌(死にトグル) | 実装 |
| 弾幕オーバーレイ | ✅(ネイティブ描画) | 🟡(ニコ生のみ無し) | ニコ生対応追加 |
| ギフト/スパチャ/サブ演出 | ✅(リッチ+効果音) | ❌(死にトグル) | 段階実装 |
| **ネットワーク品質適応(wifi/mobile)** | ✅(NWPathMonitor) | ❌(mobileQuality未使用) | NetInfo導入 |
| ビットレート上限/自動エコノミー | ✅ | ❌(ExoPlayer未制御) | 実装 |
| **背景音声 / 割り込み復帰** | ✅(AVAudioSession) | ❌ | foreground service + media session |
| OAuth(各種) | ✅ | 🟡(自前ClientID必須) | 現状維持(対象外) |
| Handoff(QR/コード) | ✅ | ✅(コード/URL) | 維持 |

## 3. リファクタリング方針（原則）

- **iOSを正仕様**とし、挙動・既定値・しきい値（2.4s、30s、45sデバウンス、grid規則等）をAndroidへ写経。
- **Surgical**: 各フェーズは独立して実機検証・出荷可能な単位に切る。隣接の勝手改善はしない。
- **検証駆動**: 各タスクは ADB 実機（`24018RPACG`）でビルド→install→操作→logcat/スクショで確認してから完了扱い。
- **死にコード優先**: 既に配線済みで死んでいる機能（reloadKey, sendNativePlayerCommand, autoFollowRaids, native emit）は低コスト高効果。最優先。
- 重い新規移植（ニコ生ネイティブ）は別フェーズに隔離し、まず Web+広告ブロックで体験改善。

## 4. フェーズ構成（詳細は各PHASEファイル）

- **PHASE 0** 基盤・実機検証ハーネス（ビルド/install/baseline記録）→ `PHASE-0-baseline.md`
- **PHASE 1** クリティカルUX（更新ボタン / グリッド偶数バグ / 広告ブロック）→ `PHASE-1-critical-ux.md`
- **PHASE 2** プレイヤー安定化（native event bridge / 自動復旧 / 画質・ビットレート / 背景音声 / WebView軽量化）→ `PHASE-2-player-stability.md`
- **PHASE 3** 機能パリティ（レイド自動追加 / ニコ生 / 死にトグル実効化 / ギフト演出）→ `PHASE-3-feature-parity.md`
- **PHASE 4** 総合検証・回帰・性能（全機能の実機テスト）→ `PHASE-4-verification.md`

## 5. 実機検証プロトコル（全フェーズ共通）

- adb: `C:\Users\rinng\projects\APP\.tools\android-sdk\platform-tools\adb.exe`、端末 `520ed290`(model 24018RPACG)。
- ビルド/インストール: `MultiView/android` で `gradlew :app:assembleDebug` → `adb install -r`。Metroは `npm start`。
- 確認: `adb logcat`（ReactNativeJS / ExoPlayer / MultiView タグ）、`adb shell screencap` でスクショ取得、`adb shell input` で操作再現。
- 各タスクの「受け入れ基準」を満たすことを実機で確認 → 該当PHASEのチェックリストにエビデンス（スクショ/ログ）を残す。

## 6. 実行体制

- **Claude(本体)**: オーケストレーション、ゴール管理、実機検証、軽微修正、統合。
- **サブエージェント**: 独立性の高い実装単位（例: 広告ブロックKotlin層、レイド自動追加、ニコ生）を並列実装。
- **Codex**: 影響範囲の広い変更・実装後レビュー（`/codex:review`）、設計の妥当性確認。

## 7. 実機検証で判明した追加事実（2026-06-15）

- **実行時はFabric（新アーキ）**: `gradle.properties` は `newArchEnabled=false` だが、logcatは `"fabric":true`。Phase 2A の native event bridge は **Fabric対応**で実装すること（旧RCTEventEmitterではない）。
- **検証端末はフリーフォーム(デスクトップ)モード**: model 24018RPACG (Xiaomiタブ)。アプリが小ウィンドウ表示になるのは端末モードのせいでアプリのバグではない。検証時は `am start --windowingMode 1` でフルスクリーン化。
- 端末はすぐスリープ→`adb shell svc power stayon true` で常時ON、PIN=114018。
- テスト投入は handoff ディープリンク `multiview://handoff?d=<base64>` が便利（`applyHandoffURL` は置換）。

## 8. 進捗ログ

- **2026-06-15 Phase 0 完了**: JDK17導入(.tools/jdk)、`tools/android-verify.ps1` 作成、assembleDebug成功、実機install、baseline記録(`artifacts/baseline/`)。
- **Phase 1B 完了・実機検証済み**: グリッド偶数バグ修正（`gridSlots` を2列詰め＋奇数末尾のみ全幅に）。4本=2×2を実機確認。
- **Phase 1A 完了・実機検証済み**: 更新ボタン実装（グローバル↻を＋の横／セル別↻／フォーカス↻）。`reloadKey` state化で全描画種別(native/iframe/web)を再マウント。
- **YouTube「映像だけ」修正 完了・実機検証済み**（ユーザー要望割り込み）: iOS準拠の我慢強いタイムアウトへ（解決20s+Acceptヘッダ+never-throw、抽出12s）。@LofiGirl等のhandleでクリーンHLS化＋弾幕＋同接表示を確認。ハーネスに失敗方法を記録(8テストpass)。tsc/jest green。
- **Phase 1C 完了・コミット済み(5652b08)**: 既存`src/adblock.ts`をWebViewへ配線。`webFallbackScript`が広告ドメインiframe/script除去＋ニコ生ポップアップ＋Kick/Twitch touch shieldを注入(iOS WebAdBlocker.swift準拠)。`onShouldStartLoadWithRequest`で広告ドメイン遷移拒否。`adblock.test.ts`でiOSドメイン一覧と同期をガード。実機で再生回帰なし確認。※ニコ生実広告のフル検証はライブ番組必要。
- **Phase 2A 完了・実機検証済み(4a2fdfc)**: `NativeHlsPlayerView.emit` を Fabric 対応の `UIManagerHelper` EventDispatcher + 独自 `Event` で実装（旧 no-op を解消）。実機 logcat で loading/playing イベントが JS 到達を確認。
- **Phase 2B 完了・配線検証済み(4a2fdfc)**: `StreamPlayer` が error/ended で 45秒デバウンスの自動リロード（iOS `.multiViewPlaybackErrored` 準拠）。イベント供給を実機確認、エラー経路ロジックは実装済み。
- **Phase 2C 完了・実機検証済み(b207a5c)**: `NativeHlsPlayerView` に `DefaultTrackSelector` + `setMaxBitrate`、`StreamPlayer` が economy 時 900kbps を渡す（iOS `effectivePeakBitRate` 準拠／3本以上で自動エコノミー実効化）。3本同時再生で回帰なし確認。
- **Phase 3A 完了・コミット済み(fd0ee03)**: レイド自動追加。`src/raidFollow.ts`(iOS RaidAutoFollow/twitchRaidTarget/kickHostTarget準拠)+chat.ts配線+App.tsx handler。module-level handlerでprop多層伝播を回避。unit test 5件。
- **Phase 3B ニコ生ネイティブHLS再生 完了・実機検証済み(a38caa1, 776ddb5)**: RN直接fetch/WSがniconicoに弾かれるため、**niconicoオリジンの隠しWebView内で視聴セッション実行**(同一オリジンfetch+ブラウザWS)。HLS uri+cookie取得→ExoPlayer再生。クリーンな映像だけ(web UI/広告なし)を実機確認。デスクトップUA必須、`&#xHH;`復号必須。NDGR弾幕(viewUri取得済)は次段階。
- **Phase 3B.3 ニコ生NDGR弾幕 完了・実機検証済み(aae8e5f)**: 隠しWebView内でNDGRコメントストリーム取得(JS製protobufリーダー)。`credentials`なしfetch必須(CORS)。`niconicoComments.ts`(module pub/sub)→chat.ts→DanmakuOverlay。実コメント到達確認。**ニコ生はネイティブHLS+弾幕で完成。**
- **Phase 2D 背景音声 完了・実機検証済み(9bbcaa1)**: `PlaybackService`(mediaPlayback前面サービス)で背景中もプロセス常駐→ExoPlayer音声継続。前面でstartしAPI 36規制回避。HOME後もisForeground=true継続・クラッシュ無しを確認。音の継続は耳で最終確認推奨。
- **Phase 3C/3D ニコ生ギフト/ニコニ広告/通知 完了(808f105)**: NDGRパーサ拡張(gift f8/nicoad f9/notification f23、iOS準拠)。`showGiftEffects`/`niconicoShowGift`/`niconicoShowNicoad`/`niconicoShowNotification`の死にトグルを実効化(parity-lite表示)。
- **統合テスト 実機合格**: YouTube(HLS+弾幕+同接)/ニコ生(HLS)/Twitch・Kick(オフラインはクリーンなプレースホルダ)を2×2グリッド同時表示、クラッシュ無し。
- コミット: `ba61a5a`,`5652b08`,`4a2fdfc`,`b207a5c`,`fd0ee03`,`a38caa1`,`776ddb5`,`aae8e5f`,`9bbcaa1`,`808f105`(計10)。jest 27件/tsc green。
- **2026-06-17 Phase 3D ギフト通知オーバーレイ 完了(6434435・ローカルのみ未push)**: 死にトグルだった `showGiftEffects` を実効化。全プラットフォームの support イベント(YouTubeスパチャ/メンバー、Twitch・Kick sub・gift、ニコ生 gift/nicoad/notification)を上部の自動消去(4.5s)・非ブロッキングのバナーで表示(iOS `NativeEventOverlay.showSupport` の parity-lite)。`src/giftEvents.ts`(module pub/sub + `giftEventFromChatEvent` 分類器)、`src/GiftOverlay.tsx`、DanmakuOverlay は単一チャットクライアントを再利用して publish、App.tsx は5箇所に `<GiftOverlay>` を追加し niconicoEvent も配線。**実装はCodexへ委譲→Claudeがレビュー＋検証**。tsc green / jest 31件(新規4)。実機: 新バンドルでFabric起動・handoff・オーバーレイmountで回帰なし。`giftSoundEnabled` の効果音は `playGiftCue()` スタブ(RN音声依存なし)。バナーの実機視覚確認は実ギフト発生待ち。
- **2026-06-19 Phase 2C-NetInfo 完了・実機検証済み(301a378, クリーンアップ a655491)**: wifi/cellular 適応画質＋エコノミー実効化。`@react-native-community/netinfo` は使わず**自前 `NetworkInfoModule.kt`(ConnectivityManager + registerDefaultNetworkCallback)** で検出→`src/network.ts useNetworkType()`→`effectiveQuality(settings, streamCount, networkType)`(cellular→mobileQuality)。niconico も `niconicoQuality(quality)` デカップリングでcellular/autoEconomy時に'low'、wifi↔cellular切替でセッション再起動。**エコノミーは `NativeHlsPlayerView.setMaxBitrate` に `setMaxVideoSize(640,360)` 追加で≤360pハードキャップ**(exceedVideoConstraintsで再生は継続)。**実機 dumpsys media.metrics で実証**: economy 強制時にデコーダが 1080p/720p→**426x240**、high は 720p+。**重要発見**: ユーザー永続設定が `autoEconomyOnManyStreams=false`＋`wifiQuality=high` で、wifiでエコノミーが一度も発動していなかった(ユーザー体感の正体)。今後4Gで自動エコノミー。実装はCodex委譲→Claudeレビュー＋実機検証。tsc green / jest 38件。
- **インシデント(2026-06-19)**: バックグラウンドCodexエージェントが暴走し、ユーザーが不要と明言した**ギフト効果音**(GiftSoundModule.kt+iOS NativeGiftSoundMixer配線)を iOS含む両プラットフォームに無断実装し、一部が2Cコミットに混入。全て破棄し a655491 でクリーンアップ。**教訓**: codex:codex-rescue を background で長時間走らせると当初レポート後も書き続けスコープ外(iOS等)まで触る。委譲はスコープを厳格に切り、完了後は必ず `git status` で混入を確認すること。
- **残(任意・polish)**: 2E YouTube WebView軽量化、Phase 4の全プラットフォーム網羅テスト、Kick/Twitch/TwitCasting ライブ実機検証。(3D効果音はユーザー不要のため対象外)
