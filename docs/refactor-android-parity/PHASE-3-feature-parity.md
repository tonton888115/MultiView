# PHASE 3 — 機能パリティ（レイド自動追加 / ニコ生ネイティブ / 死にトグル実効化 / ギフト演出）

目的: iOSにあってAndroidに無い／死んでいる機能を実装し、機能パリティを達成する。

---

## 3A. レイド自動追加（autoFollowRaids 実効化）

### 現状（根拠）
- `autoFollowRaids` はトグル＋保存のみ、実装ゼロ（grep確認）。Twitch USERNOTICE raid は danmaku の `superInfo` 強調のみ（chat.ts:142）。
- iOS: `RaidAutoFollow`(RaidAutoFollow.swift)。イベント駆動（Twitch USERNOTICE タグ / Kick Pusher host・raid イベント）で target を `addIfNeeded` → 視聴タブへジャンプ。自ホスト除外。テキスト走査は補助。

### 目標
- chat クライアント（chat.ts）の Twitch USERNOTICE（raid）/ Kick Pusher（host/raid）イベントから target channel を抽出。
- `settings.autoFollowRaids` ON 時に target を streams へ追加（重複・自ホスト除外）し、視聴タブへ反映。
- 抽出ロジックは iOS `RaidAutoFollow.detectTarget` / `kickHostTarget` / `twitchRaidTarget` を移植。

### タスク
- [ ] 3A.1 `src/raidFollow.ts` に検出・正規化ロジック移植。
- [ ] 3A.2 chat.ts の Twitch/Kick イベントから raid target 抽出を配線。
- [ ] 3A.3 add + 視聴タブ反映（重複/自ホスト除外）。

### 受け入れ基準（実機）
- autoFollowRaids ON で、レイド発生時に target が自動追加される（テスト用イベント注入 or 実レイドで確認）。
- OFF では追加されない。

---

## 3B. ニコ生 ネイティブ移植（最大の山。サブフェーズ分割）

### 現状（根拠）
- Android はニコ生を常にフルWebページ再生（playback.ts:315-324, "WebSocket視聴セッション移植が未完了"）。弾幕も無し（chat.ts:48-49 空クライアント）。広告/ポップアップ/低速ロードの最悪体験。
- iOS: `NiconicoPlayer.swift`(1712行)。watchページHTMLの `data-props` から WebSocket endpoint 取得→ niconico live WS で `startWatching`(quality, latency, single_cookie)→ HLS uri+cookie 取得→ AVPlayer。NDGR protobuf を `URLSession.bytes` でストリーム（VIEW→segment URI、SEGMENT→comment/gift/nicoad/notification）。自前protobufパーサ。低遅延設定、warmup、web フォールバック。

### 目標（iOS同等）
- AndroidでもネイティブHLS再生（ExoPlayer）＋NDGR弾幕＋gift/nicoad/notification を実現。

### サブフェーズ
- [ ] 3B.1 **視聴セッション(TS)**: watchページfetch→`data-props`パース→ WebSocket 接続→`startWatching`送信→`keepSeat`維持→ HLS uri+cookie 受領。低遅延設定(`niconicoLowLatency`)反映。
- [ ] 3B.2 **HLS再生**: 取得した HLS uri を ExoPlayer へ（cookie/ヘッダ付与）。`NativeHlsPlayerView` に cookie/header prop 追加（Kotlin）。
- [ ] 3B.3 **NDGRコメントストリーム**: 長時間バイトストリーム＋protobuf解析。RN fetch のストリーミング制約のため **Kotlin/OkHttp ネイティブモジュール** で byte stream を受け、length-delimited protobuf を解析し comment/gift/nicoad/notification を JS へ emit。VIEW→segment URI、SEGMENT→events の二段（iOS streamNDGRView/streamNDGRSegment 準拠）。
- [ ] 3B.4 **弾幕/演出配線**: 取得コメントを DanmakuOverlay へ。gift/nicoad/notification を該当オーバーレイへ。
- [ ] 3B.5 **設定実効化＋フォールバック**: `niconicoLowLatency` / `niconicoShowGift` / `niconicoShowNicoad` / `niconicoShowNotification` を反映。失敗時 web フォールバック。warmup(事前cookie)検討。
- [ ] 3B.6 **コメント投稿**: WS 経由 postComment（vpos 付き、iOS NiconicoPlayer.swift:211 準拠）。ログインcookie利用。

### 受け入れ基準（実機）
- ニコ生をネイティブHLSで再生（Webページではなく動画のみ、広告/ポップアップ無し）。
- 弾幕が流れる。gift/nicoad/notification がトグルに従い表示。
- 低遅延トグルが効く。失敗時はwebへ降格して再生継続。

### 注意
- 大規模・高リスク。3B.1→3B.6 を独立に実機検証しながら積み上げる。protobuf 解析はiOSの `protobufFields`/`LengthDelimitedProtobufReader`(NiconicoPlayer.swift:1506,1551) を厳密移植。

---

## 3C. 死にトグル実効化（ニコ生系・画質系の残り）

### 現状（根拠）
- `niconicoLowLatency`/`showGiftEffects`/`giftSoundEnabled`/`niconicoShowGift`/`niconicoShowNicoad`/`niconicoShowNotification` はUIのみ。3Bで多くが実効化されるが、横断確認が必要。

### 目標
- 全設定トグルが実際の挙動に結びつく。結びつかない物はUIから外す（iOSに無い/Android非対応なら明示）。

### タスク
- [ ] 3C.1 各トグルの参照箇所を grep で再確認し、未配線を解消 or UI撤去。
- [ ] 3C.2 設定→挙動の対応表を OVERVIEW のマトリクスへ反映。

### 受け入れ基準
- 設定画面の全トグルが実機で効果を持つ（or 意図的に存在しない旨が明確）。

---

## 3D. ギフト/スパチャ/サブ演出

### 現状（根拠）
- Android はギフト演出が死にトグル。iOS: `NativeEventOverlay.showSupport`(Rendering.swift:769) リッチ演出＋合成効果音、YouTube Super Chat / membership、Twitch/Kick sub/gift、niconico gift。

### 目標
- まず YouTube Super Chat / Twitch・Kick sub・gift・niconico gift を**簡易オーバーレイ**で表示（`showGiftEffects`）。効果音（`giftSoundEnabled`）は段階的に。
- iOSのフル演出（パーティクル/プログレスバー/合成WAV）は段階導入（必須ではない）。

### タスク
- [ ] 3D.1 chat.ts のイベント（superchat/sub/gift/nicoad）を gift overlay へ。
- [ ] 3D.2 簡易演出コンポーネント実装（`showGiftEffects`/`giftSoundEnabled` 反映）。

### 受け入れ基準（実機）
- スパチャ/サブ/ギフト発生時に通知オーバーレイが出る（トグル反映）。

---

## 実行体制
- 3A/3C/3D は中規模、サブエージェント並列。3B は最大規模で codex 主体＋本体の実機検証を密に。各サブフェーズ完了で `/codex:review`。
