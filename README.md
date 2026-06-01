# MultiView — 複数配信の同時視聴アプリ (iOS / sideload)

[English](README.en.md) ｜ 日本語

**Kick / Twitch / YouTube / ニコ生 / ツイキャス** の配信をグリッドで**同時視聴**し、コメントを
**ニコ生風に右→左へ流す弾幕**で表示する iOS アプリです。各サービスは**ネイティブプレイヤー**で再生し、
拡大表示・ドラッグ並べ替え・端末間引き継ぎ(QR)などに対応します。

Windows だけで開発でき、**クラウドの Mac (Codemagic) で未署名 IPA をビルド**し、**LiveContainer**
（推奨）または Sideloadly で iPhone にインストールします。

リポジトリ: **https://github.com/tonton888115/MultiView** (public)

> ⚠️ 個人利用・自分のアカウントでのサイドロード前提のツールです。各サービスの利用規約は各自で確認してください。

---

## 主な機能

- **下タブ 4 つ**: フォロー / ランキング / 視聴 / 設定
- **視聴タブ**: グリッド同時視聴。セルの **⤢** で 1 配信を拡大、長押しで並べ替え、**×** で削除
- **ネイティブ再生**: 5 サービスそれぞれ専用プレイヤー（Kick は Amazon IVS Player、Twitch は IVS Player 実験→AVPlayer、YouTube は HLS 抽出、ツイキャスは HLS、ニコ生は番組ページの HLS + コメント WebSocket）
- **弾幕**: ニコ生風に右→左へ流れるコメント（表示/速度/不透明度/文字サイズ/最大行数/最大文字数を設定可）。ニコ生はギフト演出も表示
- **コメント送信**: 可能なサービスはアプリ内入力欄から、未対応は拡大時の公式チャットからログインして送信
- **端末間引き継ぎ**: 視聴タブの QR ボタンで、開いているタブ一式を iPad↔iPhone に引き継ぎ（QR スキャン or クリップボード、サーバ不要）
- **低遅延チューニング**: Kick は Amazon IVS Player で低遅延化、Twitch は IVS Player 実験経路から旧 AVPlayer へ自動退避、ニコ生は設定で低遅延トグル
- **画質**: Wi-Fi / モバイルで別々に高画質/エコノミーを設定

---

## 対応サービス

| サービス | 映像 | 弾幕(右→左) | コメント送信 |
|---|---|---|---|
| Twitch | ✅ IVS Player 実験 + 旧ネイティブ HLS fallback | ✅ 匿名受信 | ✅ 拡大時に公式チャット(ログイン) |
| Kick | ✅ Amazon IVS Player (低遅延) | ✅ Pusher 受信 | ✅ ネイティブ(OAuth ログイン) |
| YouTube | ✅ HLS 抽出 | △ Data API + OAuth が必要 | ✅ 拡大時に公式ライブチャット(ログイン) |
| ツイキャス | ✅ ネイティブ HLS | ⚠️ best-effort | ✅ ネイティブ(OAuth ログイン) |
| ニコ生 | ✅ HLS + 純正コメント | 純正コメント + ギフト | ✅ ネイティブ(要 user_session ログイン) |

---

## 開発 & ビルド（Windows）

- アプリ本体は **`MultiView/ios/MultiView/*.swift`**（UIKit ネイティブ）。RN プロジェクトの足回りを流用しつつ、UI は完全ネイティブです。
- iOS のビルドには Mac が必要なので **Codemagic**（クラウド Mac）で未署名 IPA を作ります。GitHub Actions は使いません。

```powershell
# 1. 変更を main にコミット & プッシュ
git add -A; git commit -m "変更内容"; git push origin main

# 2. Codemagic でビルド → IPA を artifacts と iCloud にDL
#    (バージョン付きファイル名 MultiView-<version>-b<build>.ipa で出力されます)
tools\codemagic-build.ps1
```

> Codemagic の API トークンは `~/.codemagic/token` に保存しておきます（`codemagic.yaml` の `ios-unsigned-ipa` ワークフローをビルド）。

---

## インストール（iloader + LiveContainer 推奨）

無料 Apple ID の「7日失効・同時3アプリ」を避けやすく、再インストールも楽なので **LiveContainer** を推奨します。

1. **LiveContainer を導入**: [SideStore](https://sidestore.io) もしくは [AltStore](https://altstore.io) で LiveContainer をインストール。Windows からは [**iloader**](https://github.com/nab138/iloader) を使うと導入が簡単です。
2. **IPA を入れる**: ビルドした `MultiView-<version>-b<build>.ipa` を iPhone に渡し（iCloud Drive など）、LiveContainer の **Apps → +** から取り込む。既にある場合は**置換(replace)**、データ(ログイン Cookie)は消さない。
3. 起動 → 設定フッターの **`MultiView x.y.z (build N)`** で版数を確認。

> 💡 **更新時はファイル名にバージョンを付ける**（`MultiView-1.1.12-b21.ipa` など）。同名 `MultiView.ipa` だと iPhone 側のキャッシュで「入れたのに更新されない」事故が起きます。`tools\codemagic-build.ps1` は自動でバージョン名を付け、古い IPA を消します。
>
> **代替**: [Sideloadly](https://sideloadly.io) で直接インストールも可。無料 Apple ID は 7 日で署名失効・同時 3 アプリまで。

---

## 使い方

- **ランキング / フォロー** タブで配信をタップ → 視聴タブに追加（**＋**で手動追加も可: サービス選択 + チャンネル名 / 動画ID / ユーザーID / 番組ID）。
- グリッドは画面数で自動調整、**横向きで列が増えます**。セルの **⤢** で拡大、長押しで並べ替え、**×** で削除。
- 拡大すると動画の下にチャット(入力欄付き)。投稿には各サービスへのログインが必要。
- **設定**タブ: 音声/レイド自動追加/Web広告ブロック/画質/弾幕/ニコ生低遅延/各サービスの OAuth 連携。

---

## OAuth ログイン（各自の Client ID が必要）

アプリ内からのコメント送信や YouTube 弾幕などは各サービスの **OAuth アプリ登録**が要ります。**アプリには Client ID/Secret は同梱されていません**（既定は空）。各自で developer console に登録し、**設定タブから自分の Client ID を入力**してください。

- リダイレクト URI の既定は作者の GitHub Pages の中継ページ（`https://tonton888115.github.io/MultiView/*.html`、コードを `multiview://` に戻すだけの静的ページ）を指します。**独立して使うなら自分でホストした中継ページ**に差し替え推奨。
- YouTube は iOS クライアント ID（リバースドメイン redirect）方式。Kick は OAuth2.1 PKCE、ツイキャスは OAuth2.0。
- トークンは iOS の **Keychain** に保存されます。

---

## YouTube 抽出用 Cloudflare Worker（任意）

YouTube のライブ/DVR は **`cloudflare-worker/youtube-extractor`** の Worker が HLS manifest を返します。既定では作者の Worker（`multiview.rinngo0626.workers.dev`）を使いますが、**他人が大量に使うと作者の無料枠(10万req/日)を消費**します。自分で運用するなら:

```sh
cd cloudflare-worker/youtube-extractor
npm i && npx wrangler deploy   # 自分の *.workers.dev にデプロイ
```

デプロイ後、`Players.swift` の `extractionWorkerURL` を自分の Worker URL に変更してください。Worker に秘密情報はありません（InnerTube 利用・API キー不要）。

---

## セキュリティ / 公開について

- ✅ **ハードコードされた秘密情報なし**: API キー・パスワード・トークンはコードに含まれません。OAuth の Client ID/Secret は**ユーザーが入力**（既定は空）、アクセストークンは Keychain 保存。Worker にも秘密情報なし。
- ⚠️ **公開で露出する個人識別子（秘密ではない）**: Worker URL（`*.rinngo0626.workers.dev`）、リダイレクト中継ページ（`tonton888115.github.io`）、Bundle ID（`com.rinng.multiview`）。public リポジトリなので元々公開情報です。
- ⚠️ **他人が使う場合の論点**: ①YouTube 再生は作者の Worker を叩く（枠消費）→ 各自デプロイ推奨 ②OAuth は各自の Client ID が必要 ③リダイレクト中継ページを共用すると OAuth code が一瞬その静的ページを通る（独立運用なら自前ホスト推奨）。
- 結論: **ソース公開自体は安全**（秘密の流出なし）。共有インフラ(Worker/中継ページ)を他人に使われたくなければ、各自デプロイ＆自分の Client ID を案内してください。

---

## 既知の制限

- **iOS ビルドは Windows 単体不可** — クラウド Mac (Codemagic) が必要。
- **無料 Apple ID**: 署名は 7 日失効。LiveContainer 運用だと再インストール負担が小さい。
- **YouTube 弾幕**は Data API + OAuth が必要（視聴・チャット入力は可能）。
- **Kick の遅延**: 1.1.25 以降は Amazon IVS Player を優先。失敗時だけ旧 AVPlayer 経路へ戻します。
- **Twitch の遅延**: 1.1.26 以降は IVS Player 実験経路を先に試し、未対応・不安定なら自動で旧 AVPlayer 経路へ戻します。
- 同時視聴は端末性能次第で **3〜4 画面**が実用上限。
- 配信/チャットは各サイトの仕様変更で壊れることがあります。
