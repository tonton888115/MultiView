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
- **未着手**: Phase 1C(広告ブロック)、Phase 2(安定化: native event bridge/自動復旧/画質/背景音声)、Phase 3(レイド/ニコ生ネイティブ/死にトグル/ギフト)、Phase 4(総合検証)。
- 未コミット（ユーザー指示待ち）。
