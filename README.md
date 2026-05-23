# MultiView — 複数配信の同時視聴アプリ (iOS / sideload)

multikick のように **Kick / Twitch / YouTube / ニコ生 / ツイキャス** の配信をグリッドで同時視聴し、
コメントを **ニコニコ生放送風に右→左へ流す弾幕** で表示する iOS アプリです。

Windows だけで開発でき、**クラウドの Mac (GitHub Actions) で未署名 IPA をビルド**して、
**Sideloadly** で自分の Apple ID により iPhone へインストールします。

リポジトリ: **https://github.com/tonton888115/MultiView** (public)

---

## 主な機能

- **下タブ 4 つ**: フォロー / ランキング / 視聴 / 設定
- **ランキングタブ**: [ikioi-ranking](https://ikioi-ranking.com) を表示し、配信をタップするだけで同時視聴に追加
- **フォロータブ**: 各サービスにログインして、フォロー中の配信をタップで追加
- **視聴タブ**: グリッド同時視聴。セルの **⛶** で拡大すると、動画の下にチャット(入力欄付き)が出る
- **弾幕**: ニコ生風に右→左へ流れるコメント
- **Dr.Maggot 風フィルタ**: NG ワード / NG ユーザー / 最大文字数、弾幕の速度・不透明度・文字サイズ・最大行数
- **自己完結**: プレイヤー HTML をアプリに内蔵。**GitHub Pages も URL 入力も不要**

---

## 構成

```
APP/                    ← git リポジトリのルート
├─ MultiView/           ← React Native アプリ
│  ├─ App.tsx           ← タブ・グリッド・状態
│  └─ src/
│     ├─ playerHtml.ts  ← 内蔵プレイヤー(埋め込み+弾幕+チャット受信)
│     ├─ components/    ← タブ・グリッド・セル・設定 など
│     └─ parseStreamUrl.ts ← ランキング等のリンク→配信判定
├─ cloudflare-worker/   ← (任意) Kick/ツイキャスのコメント用 CORS プロキシ
└─ .github/workflows/   ← 未署名 IPA を作る CI
```

プレイヤーは `source={{ html, baseUrl }}` でアプリ内 HTML を読み込みます。Twitch の埋め込み要件
(`parent`)は `baseUrl` のホスト (`multiview.local`) を使って満たしています。

---

## 対応サービス

| サービス | 映像 | 弾幕(右→左) | コメント送信 |
|---|---|---|---|
| Twitch | ✅ | ✅ 匿名受信 | ✅ 拡大時に公式チャット(ログイン) |
| Kick | ✅ | ⚠️ Worker 任意 | ✅ 拡大時にネイティブ(ログイン) |
| YouTube | ✅ | ✖️ (API 必要) | ✅ 拡大時に公式ライブチャット(ログイン) |
| ツイキャス | ✅ | ⚠️ best-effort | ✅ 拡大時にネイティブ(ログイン) |
| ニコ生 | △ 番組ページを直接表示 | 純正コメント | ✅ 番組ページ内で入力 |

> ニコ生のライブは公式 iframe 埋め込みが無いため番組ページを直接表示します(純正の映像+コメント)。
> YouTube のライブチャット弾幕は API が必要なため未対応(視聴とチャット入力は可能)。

---

## ビルド & インストール

### 1. 変更を push (リポジトリは作成済み)

```powershell
git add -A
git commit -m "変更内容"
git push
```

> public なので GitHub Actions の macOS ビルドは無料です。

### 2. 未署名 IPA をビルド

**Actions タブ → 「Build iOS (unsigned IPA)」**(`MultiView/` を push すると自動実行)。
完了後、実行画面下部の **Artifacts** から `MultiView-unsigned-ipa` をDL → 展開して `MultiView.ipa` を取得。

### 3. Sideloadly でインストール

1. Windows に **Sideloadly** (https://sideloadly.io) と **Apple 配布版**の iTunes / iCloud を入れる。
2. iPhone を USB 接続。iOS 16+ は **設定 → プライバシーとセキュリティ → デベロッパモード** を ON。
3. Sideloadly に `MultiView.ipa` をドラッグ → Apple ID 入力 → **Start**。
4. iPhone の **設定 → 一般 → VPN とデバイス管理** で自分の Apple ID を信頼 → 起動。

> 無料 Apple ID は **7 日で署名失効**(都度再インストール)、**同時 3 アプリ**まで。

**初回起動後すぐ使えます**(URL 入力などの初期設定は不要)。

---

## 使い方

- **ランキング / フォロー** タブで配信をタップ → 視聴タブに追加。
- **＋**(視聴タブ右下)で手動追加も可能(サービス選択 + チャンネル/動画ID/番組ID)。
  - Kick / Twitch … チャンネル名、YouTube … 動画ID、ツイキャス … ユーザーID、ニコ生 … 番組ID
- グリッドは画面数で自動調整、**横向きで列が増えます**。セル右上の **×** で削除、**⛶** で拡大。
- 拡大すると動画の下にチャット(入力欄付き)が出ます。投稿には各サービスへのログインが必要。
- **設定**タブで弾幕の表示・NG フィルタ・速度などを調整。
- 同時視聴は **4 画面程度**が快適です。音声はミュート起動なので、聞きたい配信をタップして解除。

---

## (任意) Kick / ツイキャスの弾幕を安定させる

Kick の `chatroom_id` 取得やツイキャスのコメント取得は CORS で弾かれることがあります。
無料の Cloudflare Worker を立てると安定します。

1. https://workers.cloudflare.com で Worker を作成し `cloudflare-worker/worker.js` を貼って Deploy。
2. **設定タブ → CORS プロキシ** に `https://xxx.workers.dev/?url=` を設定。

> Kick は bot 対策が強く Worker 経由でも弾かれることがあります。ツイキャスは概ね動きます。

---

## フェーズ2 (未実装): アプリ内の統一入力欄から API 送信

現在のコメント送信は「拡大時に各サービスのチャット UI でログインして入力」方式です。
「アプリ内の 1 つの入力欄から送る」には各サービスの **OAuth アプリ登録(client ID)** が必要
(Kick = OAuth2.1 PKCE、ツイキャス = OAuth2.0)。client ID を用意できれば実装します。

---

## 既知の制限

- **iOS ビルドは Windows 単体では不可** — クラウド Mac (本リポジトリの GitHub Actions) が必要。
- **無料 Apple ID**: 7 日失効・同時 3 アプリ。継続運用は毎週再署名 or AltStore。
- **YouTube 弾幕**は未対応(ライブチャット API が必要)。視聴とチャット入力は可能。
- **同時視聴数**: 端末性能次第で 3〜4 画面が実用上限。
- 配信/チャットは各サイトの仕様変更で壊れることがあります(その場合は `src/playerHtml.ts` を修正して再ビルド)。
