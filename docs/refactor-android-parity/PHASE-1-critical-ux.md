# PHASE 1 — クリティカルUX（更新ボタン / グリッド偶数バグ / 広告ブロック）

目的: ユーザーが明示した3大不満を、低リスク・高効果で潰す。死にコードの実効化が中心。

---

## 1A. 更新（リロード）ボタン

### 現状（根拠）
- `reloadKey` は `StreamCell`/`StreamPlayer`/`FocusModal` に配線済みだが全箇所 `0` 固定（App.tsx:745, 793, 2012）。インクリメントされず、WebView/native の `key` 再マウントが発火しない。
- `sendNativePlayerCommand(handle, 'reload')`（NativeHlsPlayer.tsx:34-43）は実装済みだが**未呼び出し**。native側 `reload` も実装済み（NativeHlsPlayerManager.kt:62-78 / NativeHlsPlayerView.kt:124-126）。
- iOS仕様: グローバル更新ボタン（ViewingUI.swift:270, `arrow.triangle.2.circlepath`）が全プレイヤーを作り直す。セル別手動更新はiOSには無いが、自動復旧の無いAndroidでは**セル別更新も追加**するのが有用。

### 目標
- **グローバル更新ボタン**を視聴タブ下部コントロール（App.tsx:762-779、現状は layout toggle と ＋ のみ）に追加。iOS同様 `arrow.triangle.2.circlepath` 相当アイコン。押下で全ストリームを再読込（reloadKey 全体インクリメント or 各セルへ reload 指令）。
- **セル別更新ボタン**を `StreamCell` のコントロール群（App.tsx:935-976）に追加（× / ↗ / □ に並べる）。押下でそのセルのみ再読込。
- native は `sendNativePlayerCommand('reload')`、WebView/iframe は `reloadKey` インクリメントで再マウント。

### タスク
- [ ] 1A.1 `reloadKey` を state 化（グローバル＋セル別 Map）。`0`固定を撤去。
- [ ] 1A.2 グローバル更新ボタン追加＋全セル reload 配線。
- [ ] 1A.3 セル別更新ボタン追加＋単一セル reload 配線。
- [ ] 1A.4 native パス: `sendNativePlayerCommand` を import して reload 指令を送る（ref/handle 取得経路を整備）。

### 受け入れ基準（実機）
- 視聴タブにグローバル更新ボタンが見える。押すと全ストリームが再読込され再生再開。
- 各セルに更新ボタンが見え、押すとそのセルだけ再読込。
- ネイティブ(Kick/Twitch等)・iframe(YouTube)・web(ニコ生)いずれでも更新が効く（logcatで再読込確認）。

---

## 1B. グリッド偶数バグ

### 現状（根拠）
- `gridSlots`（App.tsx:804-815）: `bigCount = streams.length % 2 === 0 ? 2 : 1` → 偶数だと末尾2セルが全幅化し2列タイルにならない（2本グリッド＝実質スタック表示）。
- iOS正仕様 `addGrid`（ViewingUI.swift:307-324）: `bigCount = count % 2 == 0 ? 2 : 1`、`pairedCount = count - bigCount`。**ペア部分は2列(50%)、末尾 bigCount 本は全幅(100%)。** つまり 1→大1, 2→大2(全幅2段), 3→ペア1+大1, 4→ペア1+大2, 5→ペア2+大1 …
- 重要: iOSとAndroidの**式は同じ**だが、iOSは「2本=全幅2段」が意図仕様。ユーザーが「偶数バグ」と感じるのは、偶数時に2列にならない点。**iOS準拠に揃えるか、ユーザー期待（偶数も2列タイル）に変えるかを決める。**

### 目標（決定: ユーザー体験優先＝偶数も綺麗に2列タイル）
- グリッドは「**先頭から2列で詰め、奇数なら最後の1本だけ全幅**」に統一する（= `bigCount = count % 2 === 0 ? 0 : 1`）。これにより 2→2列, 4→2×2, 3→2列+全幅1, と直感的なタイルになる。
- ※iOSの「末尾2本全幅」挙動はバグ報告の主因なので、Android側は2列詰めに修正。必要ならiOS側も同調を別途検討（本フェーズ対象外）。

### タスク
- [ ] 1B.1 `gridSlots` を「2列詰め＋奇数末尾のみ全幅」に修正。
- [ ] 1B.2 セル高さ計算（50%幅時 16:9、全幅時 16:9）を破綻なく。
- [ ] 1B.3 ドラッグ並び替え・フォーカス・追加/削除時のレイアウト整合を確認。

### 受け入れ基準（実機）
- 2本グリッド = 横2列（before/afterスクショ比較）。3本 = 2列+全幅1。4本 = 2×2。
- 追加/削除/並び替えでレイアウトが崩れない。

---

## 1C. 広告ブロック

### 現状（根拠）
- `blockWebAds`(既定ON) は `webFallbackScript` の DOM 非表示(App.tsx:2654-2670)のみ。ネットワーク級・プリロール・ニコ生広告は素通り。
- iOS: `WebAdBlocker`(WKContentRuleList, WebAdBlocker.swift) で広告ドメインの image/script/media 等をネットワークレベルでブロック。niconicoポップアップブロッカー(AppDelegate.swift:386)、埋め込みtouch shield(AppDelegate.swift:405)。

### 目標
- **ネットワーク級ブロック**を Android の WebView に導入。RNの `react-native-webview` だけでは難しいため、**Kotlin の `WebViewClient.shouldInterceptRequest`** で広告ドメインを遮断する仕組みを検討（カスタムWebViewor設定）。最低限、`onShouldStartLoadWithRequest`(JS側)＋注入スクリプトで主要広告/プリロールを抑止。
- iOSと同じ広告ドメインリスト（doubleclick, googlesyndication, imasdk.googleapis(IMA=動画広告), amazon-adsystem, adnxs, taboola, outbrain 等。WebAdBlocker.swift:36）を共有定数化。
- **niconicoポップアップブロッカー**スクリプト（"快適視聴/プレミアム会員"モーダル非表示, AppDelegate.swift:386 を移植）を niconico WebView に注入。
- **埋め込みプレイヤー touch shield**（`#player iframe,#player video{pointer-events:none}`, AppDelegate.swift:405 / player.html:10）を Kick/Twitch の web フォールバックに注入。

### タスク
- [ ] 1C.1 広告ドメイン定数を `src/adblock.ts` に定義（iOS WebAdBlocker.swift:36 と同一）。
- [ ] 1C.2 WebView 注入スクリプト強化: ネットワーク要求の握り潰し（`onShouldStartLoadWithRequest` で広告ドメイン拒否）＋ IMA/動画広告 iframe の除去。
- [ ] 1C.3 niconico ポップアップブロッカー注入（MutationObserver）。
- [ ] 1C.4 Kick/Twitch web フォールバックへ touch shield 注入。
- [ ] 1C.5 （発展）Kotlin カスタム WebViewClient で `shouldInterceptRequest` によるドメイン遮断を評価・導入。

### 受け入れ基準（実機）
- ニコ生（web再生）でポップアップ/広告オーバーレイが出ない（before/afterスクショ）。
- 広告ドメインへの要求が遮断される（logcat/network で確認）。
- `blockWebAds` OFF で従来挙動に戻る（トグルが実効）。

---

## 実行体制
- 1A/1B は Claude本体で直接（小規模・JS）。1C はサブエージェント1体に実装委譲（広告ドメイン共有＋JS注入＋Kotlin検討）し、本体が実機検証。完了後 `/codex:review` で差分レビュー。
