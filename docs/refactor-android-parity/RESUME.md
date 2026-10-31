# 再開プロンプト — MultiView Android パリティ・リファクタリング

> このファイルは新セッションで作業を再開するための自己完結メモ。
> 「続き」「リファクタリングの続き」と言われたら、まず本ファイルと `00-OVERVIEW.md` を読み、下の「次にやること」から再開する。

## 1行サマリ
iOS(完全ネイティブSwift, `ios/MultiView/*.swift`, 約14,300行)を**リファレンス仕様**として、Android(React Native: `App.tsx` + `src/` + Kotlinネイティブモジュール)を**機能パリティ**へ引き上げる大規模リファクタ。iOSとAndroidは別実装。

## 2026-10-31 全体監査（ブランチ `claude/serene-faraday-yc7i3z`、未ビルド・未実機検証）
ユーザー報告「視聴タブをドラッグしても場所の移動ができない」＋全体監査。**APK 再ビルド(Kotlin 変更あり)と Codemagic iOS ビルド、ADB 実機確認が未実施。**
- **並び替え(Android)**: 原因は `StreamCell` の PanResponder が `useMemo([index…])` で作り直され、並べ替えのたびに gestureState(dx/dy) が 0 に戻り元位置へ戻ること。`src/StreamGrid.tsx` に作り直し: セルは id 順で描画固定・位置は transform(ネイティブドライバ)、ドラッグ中は他セルをプレビュー移動し離した時に1回だけ `onMove(id, index)`。ハンドル(≡)は即ドラッグ、セル本体は長押し(320ms)。端で自動スクロール。ネイティブ `MultiViewReorderHandle`(ReorderHandleViewManager.kt)が ACTION_DOWN で ScrollView の横取りを禁止(旧 APK では View にフォールバック)。テスト: `streamGrid.test.tsx`/`gridLayout.test.ts`。
- **並び替え(iOS)**: ドラッグ中の reload(レイド追加・設定変更・回線切替・エラー復旧)がセルを外してドラッグを中断していた → ドラッグ中は保留し指を離した後に実行。ニコ生のエラー通知は stream.id 付きにして**その配信だけ**作り直す(以前は全配信を作り直し)。グリッド偶数本も「2列詰め・奇数のみ末尾全幅」に統一(Android と同じ)。
- **Fabric は props が1つ変わるだけで全 props を再送する**(enablePropsUpdateReconciliationAndroid=false)。`NativeHlsPlayerView.setSourceUrl` が毎回 prepare し直し、音量/ミュート変更のたびに配信が再読込されていた → URL 変化時のみ、`onAfterUpdateTransaction` で1回だけ prepare。BEHIND_LIVE_WINDOW はネイティブで即復旧。
- 弾幕: レイアウト/設定変更のたびにチャット接続を張り直していた(起動直後に必ず1回、設定トグルで全配信) → ref 化し接続は配信と表示ON/OFFの変化時のみ。`danmakuOverlay.test.tsx` は旧実装で失敗することを確認済み。
- その他: 音量スライダーの座標ずれ・操作中の App 全体再描画/保存、自動復旧の45秒窓内エラー破棄、Web/iframe の初期音量未反映、iframe優先時の無限再解決、YouTube @handle の /live 重複取得(共有+キャッシュ)、同接数の通信量削減(両PF)、Twitch トークン期限を1時間と誤推定、Helix の is_sent:false、注入スクリプトの全DOM走査の間引き、Android 15+ の画面端(safe-area)、PlaybackService を START_NOT_STICKY。
- Kotlin は Android SDK を取得できない環境のため、実 android.jar(Robolectric android-all, API 35)＋RN/media3 のスタブで構文・型チェックのみ実施。

## いまの状態（2026-06-19 / HEAD=b645d86 まで全て push 済み＝Codemagic iOS ビルド実行中）
- **エコノミー画質 360p 以下に統一(2026-06-19)**: ユーザー「エコノミーでも画質良く通信量すごい」。Android は 2C で既に 640×360 キャップ済み。iOS は **ビットレート上限(900kbps)のみで解像度キャップ無し**(YouTubeは何も未設定)だったため、`NetworkQuality.effectiveMaximumResolution`(640×360 when economy)を追加し全 AVPlayer プレイヤー＋YouTube に `preferredMaximumResolution` を適用(b645d86, push済→iOSビルド)。両PFでエコノミー=≤360p。

- **Phase 0 基盤**: ✅ 完了
- **Phase 1 クリティカルUX**: ✅ 更新ボタン(↻) / グリッド偶数バグ修正 / 広告ブロック配線
- **Phase 2 安定化**: ✅ 2A native event bridge(Fabric) / 2B 自動復旧(error,ended→45s reload) / 2C ビットレート上限(自動エコノミー) / 2D 背景音声(前面サービス) / **2C-NetInfo(301a378,a655491): wifi/cellular検出→4Gで`mobileQuality`自動適用＋エコノミーを実効化(≤360pハードキャップ)**。❌ 2E YouTube WebView軽量化
- **Phase 3 機能パリティ**: ✅ 3A レイド自動追加 / 3B **ニコ生ネイティブHLS再生＋NDGR弾幕** / 3C 死にトグル実効化(ニコ生系) / 3D ニコ生 gift・ニコニ広告・通知(簡易表示) / **3D ギフト通知オーバーレイ(6434435, `showGiftEffects`実効化)**: 全プラットフォームの support イベント(YouTubeスパチャ/メンバー, Twitch・Kick sub・gift, ニコ生gift/nicoad/notification)を上部の自動消去バナーで表示(iOS NativeEventOverlay.showSupport の parity-lite)。`src/giftEvents.ts`(module pub/sub)+`src/GiftOverlay.tsx`。❌ `giftSoundEnabled`効果音(playGiftCueはRN音声依存が無いためスタブ。1行で有効化可) / iOS級のリッチ演出(パーティクル/プログレスバー/合成WAV)
- **Phase 4 総合検証**: 🟡 4配信2×2の統合動作のみ確認。全網羅は未
- 追加: ネイティブプレイヤーのアスペクト比バグ修正(TextureView化＋隠しWebViewの`containerStyle`)

ユーザーの当初4大不満(広告/更新ボタン/不安定/機能欠落)＋ニコ生ネイティブ化＋背景音声は概ね解消済み。

## 次にやること（優先度順）
1. **Kick / Twitch / TwitCasting をライブ実機検証**（実装済みだがライブ配信を捕捉できず未検証。アスペクト比修正の恩恵も要確認）。ライブ探索: Twitch GQL `user(login){stream{id}}`(Client-ID `kimne78kx3ncx6brgo4mv6wki5h1ko`), Kick `kick.com/api/v2/channels/{slug}`(sandboxからはCloudflareで403なので端末で), TwitCasting `streamserver.php?target=X&mode=client`。
2. ~~2C NetInfo~~ ✅完了(301a378): **`@react-native-community/netinfo` は使わず自前 `NetworkInfoModule.kt`(ConnectivityManager)** で wifi/cellular 検出→`src/network.ts`の`useNetworkType()`→`effectiveQuality(settings,streamCount,networkType)`。エコノミーは Kotlin で `setMaxVideoSize(640,360)` も追加し**≤360pハードキャップ**(media.metricsで1080p→426x240 を実測)。**重要な実機発見**: ユーザー設定が `autoEconomyOnManyStreams=false`＋`wifiQuality=high` のため、これまでwifiでエコノミーが一度も発動していなかった(=「エコノミーなのに高画質」の正体)。4Gでは今後 mobileQuality(=economy) が自動適用される。**効果音(`giftSoundEnabled`)はユーザーが不要と明言→実装しない**。
3. **3D 残り(効果音＋リッチ演出)**: バナー表示は実装済み(6434435)。残るは `giftSoundEnabled` の効果音(`GiftOverlay.tsx` の `playGiftCue()` スタブを実装。RN音声依存=要rebuild、または合成回避策) と、iOS級のリッチ演出(パーティクル/プログレスバー)。iOS `Rendering.swift` NativeEventOverlay 準拠。**バナーの実機視覚確認は実ギフト発生待ち**(静的tsc/jest＋実機回帰なしは確認済み)。
4. **2E YouTube WebView 軽量化**: 1配信で最大3 WebView(iframe+視聴者数+チャットbridge)を削減。
5. **Phase 4 全プラットフォーム網羅テスト** ＋ **Codex完全監査**(範囲を小さく分割して途中死回避)。

## 環境・手順（重要）
- 実機: `520ed290`(model 24018RPACG, Xiaomiタブ, **Android 15 / API 36**)。**フリーフォーム表示**なので検証は `am start --windowingMode 1 -n com.multiview/com.multiview.MainActivity` でフルスクリーン化。**画面ロックPIN=114018**（`wm dismiss-keyguard`→`input text 114018`→`keyevent 66`）。すぐスリープするので `svc power stayon true`。
- adb: `C:\Users\rinng\projects\APP\.tools\android-sdk\platform-tools\adb.exe`
- JDK: `C:\Users\rinng\projects\APP\.tools\jdk\jdk-17.0.19+10`（`JAVA_HOME`に設定）
- ビルド: `MultiView/android` で `gradlew.bat :app:assembleDebug -Dorg.gradle.java.home=<JDK>`。APK= `app/build/outputs/apk/debug/app-debug.apk` → `adb install -r`。
- Metro: `MultiView` で `npx react-native start`（落ちたら再起動）＋ `adb reverse tcp:8081 tcp:8081`。**JS変更はFast Refresh(rebuild不要)／Kotlin・manifest変更はフルrebuild**。
- ヘルパー: `tools/android-verify.ps1`（build/install/logcat/shot）。
- テスト投入: handoffディープリンク `am start -a android.intent.action.VIEW -d "multiview://handoff?d=<urlencoded base64 of {"v":1,"s":[{"p":platform,"c":channel}],"layout":"stacked|grid"}>"`（`applyHandoffURL`は置換）。
- ニコ生ライブ番組ID: `https://live.nicovideo.jp/front/api/pages/recent/v1/programs?status=onair&offset=0` の `lv…`（**先頭は準備中の黒画面が多い。リスト後方=配信開始が古い番組ほど映像が出ている**）。
- 検証: 必ずADB実機（AGENTS.md準拠、エミュ不可）。jest=`npm test`(現状27件), 型=`npx tsc --noEmit`。

## 既知の落とし穴（再発防止）
- **Fabric(新アーキ)では props 更新のたびに全 props が ViewManager の setter に再送される**。setter は冪等にし、重い処理(prepare 等)は値が変わった時だけ `onAfterUpdateTransaction` でまとめて行う。
- **ジェスチャー処理(PanResponder 等)を変わりやすい値に依存して作り直さない**。ドラッグ中の状態は ref で持つ。リストの並べ替えで React の子要素順を入れ替えるとネイティブビューが付け替わり、TextureView/WebView の映像が瞬くので、描画順は固定して transform で位置を動かす。
- react-native-webview の隠しWebViewは `style` だけだと外側コンテナの既定`flex:1`が残り、flex兄弟として領域を奪う。**必ず `containerStyle` も絶対配置に**(`hiddenBridgeWeb`に`flex:0`)。
- RNでネイティブ動画ビューは **TextureView**（SurfaceViewはRN動的レイアウトでリサイズ失敗）。
- ニコ生はRN直fetch/WSがanti-botで弾かれる→**niconicoオリジンを読み込んだ隠しWebView内**でfetch+WS+NDGRを実行(`src/niconico.ts`)。data-propsは`&#xHH;`16進エンティティ復号必須。NDGR fetchは`credentials`を付けない(CORS)。デスクトップUA必須(sp版回避)。
- 多数JS変更後にFast Refreshでhooks順序エラー→`am force-stop`→再起動でクリア。
- Codex: `/codex:setup`でready確認→`codex:codex-rescue`サブエージェント。長時間タスクは接続再試行で途中死しやすい→範囲を小さく。

## 参照
- ゴール/マトリクス: `docs/refactor-android-parity/00-OVERVIEW.md`、各 `PHASE-*.md`
- メモリ: `multiview-android-parity-refactor` / `multiview-ios-vs-android-arch` / `youtube-video-only-preference` / `multiview-build-release-flow`
- 作業方針: 確認不要で進めてよい。フェーズ単位でコミット、各機能はADB実機検証、pushは指示時（push→Codemagic iOSビルド）。
