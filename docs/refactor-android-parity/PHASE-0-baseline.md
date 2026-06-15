# PHASE 0 — 基盤整備 & 実機検証ハーネス

目的: 以降の全フェーズの土台。現状AndroidをビルドしてADB実機に入れ、**今の挙動をエビデンス付きで記録**（baseline）し、回帰判定の基準を作る。

## 前提・環境
- adb: `C:\Users\rinng\projects\APP\.tools\android-sdk\platform-tools\adb.exe`
- 端末: `520ed290` (model 24018RPACG, product sheng_global)
- RN: 0.85.3 / React 19.2.3 / Hermes / 新アーキ(Fabric)前提
- Android module: `MultiView/android`（`com.multiview`）

## タスク
- [ ] 0.1 SDK/JDK/Gradle のローカル整備確認（`.tools/android-sdk`）。`local.properties` の `sdk.dir` を確認/生成。
- [ ] 0.2 デバッグビルド: `MultiView/android` で `./gradlew :app:assembleDebug`（初回は時間がかかる）。失敗時はログを保存し原因切り分け。
- [ ] 0.3 インストール: `adb -s 520ed290 install -r app-debug.apk`。Metro起動: `npm start`（別プロセス）。
- [ ] 0.4 baseline記録（`artifacts/baseline/` に保存、コミットしない）:
  - 各タブのスクショ（`adb shell screencap`）
  - 視聴タブで Kick/Twitch/YouTube/TwitCasting/niconico を1本ずつ追加した時の挙動・スクショ
  - グリッド表示を 2,3,4 本で撮影（偶数バグの現物）
  - 広告の出る様子（特にニコ生）のスクショ
  - 「更新ボタンが無い」ことの確認
  - `adb logcat` を1分キャプチャ（ReactNativeJS / ExoPlayer / AndroidRuntime）
- [ ] 0.5 検証ヘルパースクリプトを `tools/android-verify.ps1` に用意（build→install→logcat→screencap のワンショット）。

## 受け入れ基準
- 実機でアプリが起動し、4タブと視聴タブの基本操作ができる。
- baselineスクショ/ログが `artifacts/baseline/` に揃い、PHASE 1以降の before/after 比較ができる。
- ビルド/インストール/ログ取得が `tools/android-verify.ps1` 一発で再現できる。

## 実行体制
- Claude本体（ビルド・実機操作はホストでしか出来ないため本体が実施）。ビルド失敗の調査が重い場合のみ codex 併用。
