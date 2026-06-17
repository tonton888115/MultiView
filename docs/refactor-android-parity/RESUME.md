# 再開プロンプト — MultiView Android パリティ・リファクタリング

> このファイルは新セッションで作業を再開するための自己完結メモ。
> 「続き」「リファクタリングの続き」と言われたら、まず本ファイルと `00-OVERVIEW.md` を読み、下の「次にやること」から再開する。

## 1行サマリ
iOS(完全ネイティブSwift, `ios/MultiView/*.swift`, 約14,300行)を**リファレンス仕様**として、Android(React Native: `App.tsx` + `src/` + Kotlinネイティブモジュール)を**機能パリティ**へ引き上げる大規模リファクタ。iOSとAndroidは別実装。

## いまの状態（2026-06-17 / 全て push 済み, HEAD=221d3f2）
- **Phase 0 基盤**: ✅ 完了
- **Phase 1 クリティカルUX**: ✅ 更新ボタン(↻) / グリッド偶数バグ修正 / 広告ブロック配線
- **Phase 2 安定化**: ✅ 2A native event bridge(Fabric) / 2B 自動復旧(error,ended→45s reload) / 2C ビットレート上限(自動エコノミー) / 2D 背景音声(前面サービス)。❌ 2C-NetInfo(wifi/mobile別画質, `mobileQuality`未使用) / 2E YouTube WebView軽量化
- **Phase 3 機能パリティ**: ✅ 3A レイド自動追加 / 3B **ニコ生ネイティブHLS再生＋NDGR弾幕** / 3C 死にトグル実効化(ニコ生系) / 3D ニコ生 gift・ニコニ広告・通知(簡易表示)。❌ 3D YouTubeスパチャ/Twitch・Kick sub・gift のリッチ演出＋効果音
- **Phase 4 総合検証**: 🟡 4配信2×2の統合動作のみ確認。全網羅は未
- 追加: ネイティブプレイヤーのアスペクト比バグ修正(TextureView化＋隠しWebViewの`containerStyle`)

ユーザーの当初4大不満(広告/更新ボタン/不安定/機能欠落)＋ニコ生ネイティブ化＋背景音声は概ね解消済み。

## 次にやること（優先度順）
1. **Kick / Twitch / TwitCasting をライブ実機検証**（実装済みだがライブ配信を捕捉できず未検証。アスペクト比修正の恩恵も要確認）。ライブ探索: Twitch GQL `user(login){stream{id}}`(Client-ID `kimne78kx3ncx6brgo4mv6wki5h1ko`), Kick `kick.com/api/v2/channels/{slug}`(sandboxからはCloudflareで403なので端末で), TwitCasting `streamserver.php?target=X&mode=client`。
2. **2C NetInfo**: `@react-native-community/netinfo` 導入→wifi/cellular検出→`mobileQuality`実効化(新規依存=要rebuild)。
3. **3D リッチなギフト演出**: chat.ts のスパチャ/サブ/ギフトを演出オーバーレイ＋効果音(`showGiftEffects`/`giftSoundEnabled`)。iOS `Rendering.swift` NativeEventOverlay 準拠。
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
- react-native-webview の隠しWebViewは `style` だけだと外側コンテナの既定`flex:1`が残り、flex兄弟として領域を奪う。**必ず `containerStyle` も絶対配置に**(`hiddenBridgeWeb`に`flex:0`)。
- RNでネイティブ動画ビューは **TextureView**（SurfaceViewはRN動的レイアウトでリサイズ失敗）。
- ニコ生はRN直fetch/WSがanti-botで弾かれる→**niconicoオリジンを読み込んだ隠しWebView内**でfetch+WS+NDGRを実行(`src/niconico.ts`)。data-propsは`&#xHH;`16進エンティティ復号必須。NDGR fetchは`credentials`を付けない(CORS)。デスクトップUA必須(sp版回避)。
- 多数JS変更後にFast Refreshでhooks順序エラー→`am force-stop`→再起動でクリア。
- Codex: `/codex:setup`でready確認→`codex:codex-rescue`サブエージェント。長時間タスクは接続再試行で途中死しやすい→範囲を小さく。

## 参照
- ゴール/マトリクス: `docs/refactor-android-parity/00-OVERVIEW.md`、各 `PHASE-*.md`
- メモリ: `multiview-android-parity-refactor` / `multiview-ios-vs-android-arch` / `youtube-video-only-preference` / `multiview-build-release-flow`
- 作業方針: 確認不要で進めてよい。フェーズ単位でコミット、各機能はADB実機検証、pushは指示時（push→Codemagic iOSビルド）。
