# MultiView — 複数配信の同時視聴アプリ (iOS / sideload)

multikick のように **Kick / Twitch / ニコ生 / ツイキャス** の配信をグリッドで同時視聴し、
コメントを **ニコニコ生放送風に右→左へ流す弾幕** で表示する iOS アプリです。

Windows だけで開発でき、**クラウドの Mac (GitHub Actions) で未署名 IPA をビルド**して、
**Sideloadly** で自分の Apple ID により iPhone へインストールします。

---

## 構成

```
APP/                       ← git リポジトリのルート
├─ MultiView/              ← React Native アプリ本体 (薄いシェル)
│  ├─ App.tsx / src/       ← グリッド・配信追加・設定
│  └─ ios/                 ← Xcode プロジェクト
├─ docs/                   ← GitHub Pages で公開する部分 (主役)
│  ├─ player.html          ← 各サービスの埋め込み + 弾幕 + チャット受信
│  └─ index.html           ← ブラウザ動作確認用ページ
├─ cloudflare-worker/      ← (任意) Kick/ツイキャスのコメント用 CORS プロキシ
└─ .github/workflows/      ← 未署名 IPA を作る CI
```

**設計の要点**: 配信・チャットなど壊れやすいロジックは `docs/player.html` (GitHub Pages) に置いてあります。
各サイトの仕様変更で動かなくなっても、**IPA を再ビルドせず `git push` だけで修正**できます。

---

## 対応状況

| サービス | 映像 | 弾幕(受信) | コメント送信(入力) |
|---|---|---|---|
| Twitch | ✅ | ✅ 匿名で受信 | ✅ 公式チャット埋め込み(ログイン) |
| Kick | ✅ | ⚠️ Worker任意 | ✅ ネイティブchatパネル(ログイン) ／ 将来API |
| ツイキャス | ✅ | ⚠️ best-effort | ✅ ネイティブページ(ログイン) ／ 将来API |
| ニコ生 | △ 番組ページを直接表示 | 純正コメント | ✅ 番組ページ内で入力 |

> ニコ生のライブは公式の iframe 埋め込みが無く、コメントも Protobuf ストリーミングのため、
> v1 では番組ページ (`live.nicovideo.jp/watch/lv...`) をそのまま開きます。純正プレイヤーの
> コメントがそのまま見られます。

---

## セットアップ手順

### 1. GitHub に push (作成済み)

リポジトリは作成・push 済みです → **https://github.com/tonton888115/MultiView** (public)。
以後の変更は次でOK:

```powershell
git add -A
git commit -m "変更内容"
git push
```

> public なので GitHub Actions の macOS ビルドは無料です(private は macOS 分が 10 倍消費)。

### 2. GitHub Pages を有効化

リポジトリの **Settings → Pages** で:
- **Source**: Deploy from a branch
- **Branch**: `main` / フォルダ `/docs` → Save

数分後、**https://tonton888115.github.io/MultiView/** で公開されます。
そのURLを開いて動作確認ページが出れば OK。

### 3. 未署名 IPA をビルド

**Actions タブ → 「Build iOS (unsigned IPA)」 → Run workflow**
(または `MultiView/` 配下を push すると自動実行)。

完了したら、その実行画面の下部 **Artifacts** から `MultiView-unsigned-ipa` を
ダウンロードし、zip を展開して `MultiView.ipa` を取り出します。

### 4. Sideloadly でインストール

1. Windows に **Sideloadly** (https://sideloadly.io) と、**Apple 配布版**の iTunes / iCloud を入れる
   (Microsoft Store 版は不可)。
2. iPhone を USB 接続。iOS 16+ は **設定 → プライバシーとセキュリティ → デベロッパモード** を ON。
3. Sideloadly に `MultiView.ipa` をドラッグし、Apple ID を入力して **Start**。
4. iPhone の **設定 → 一般 → VPN とデバイス管理** で自分の Apple ID を信頼。
5. アプリを起動。

> 無料 Apple ID は **7 日で署名が失効**します。切れたら Sideloadly で再インストール(再署名)。
> 同時にインストールできる自作アプリは **3 個まで** です。

### 5. アプリ内で URL を設定

初回起動時、アプリの **⚙ 設定** を開き、**GitHub Pages のベース URL** を入力:

```
https://tonton888115.github.io/MultiView
```

(末尾の `/player.html` は不要)。保存すると配信を追加できるようになります。

### 6. (任意) Kick / ツイキャスのコメントを出す

Kick の `chatroom_id` 取得やツイキャスのコメント取得は CORS で弾かれることがあります。
無料の Cloudflare Worker を 1 枚立てると安定します。

1. https://workers.cloudflare.com で Worker を作成し、`cloudflare-worker/worker.js` を貼って Deploy。
2. URL をコピー (例 `https://multiview-proxy.<you>.workers.dev`)。
3. アプリの **⚙ 設定 → CORS プロキシ** に次を設定:
   ```
   https://multiview-proxy.<you>.workers.dev/?url=
   ```

> Kick は Cloudflare の bot 対策が強く、Worker 経由でも弾かれる場合があります。ツイキャスは概ね動きます。

---

## 使い方

- **＋** ボタン: サービスを選び、チャンネル名 / ユーザー ID / 番組 ID を入れて追加。
  - Kick / Twitch … チャンネル名 (例 `xqc`)
  - ツイキャス … ユーザー ID (例 `twitcasting_jp`)
  - ニコ生 … 番組 ID (例 `lv123456789`)
- 画面数に応じてグリッドが自動調整され、**横向きにすると列が増えます**。
- 各セル右上の **×** で削除。配信リストと設定は端末に保存されます。
- 同時視聴は **4 画面程度**が快適です (iOS の WebView 制約)。
- 音声は全画面ミュート起動。聞きたい配信をタップしてプレイヤー側でミュート解除してください。

---

## コメント入力 (送信)

各セル右上の **💬** で、その配信のチャットを開いて投稿できます(初回はログインが必要)。

- **Twitch**: 公式チャットが開き、ログインすればそのまま投稿可能。
- **Kick / ツイキャス**: ネイティブのページが開きます。ログインすると各サイトの入力欄から投稿できます。WebView 内のログインは保持されます。
- **ニコ生**: 配信セル自体が番組ページなので、ログインすればセル内で直接コメントできます(💬 は表示されません)。

> モバイルの Twitch 埋め込みチャットはログインで不調になることがあります。その場合はチャット下部の「Twitch で開く」を使ってください。

### (フェーズ2) アプリ内の統一入力欄から API 送信

Kick / ツイキャスを「アプリ内の 1 つの入力欄」から送信する方式は、各サービスでの
**OAuth アプリ登録(client ID 取得)** が前提です。client ID を用意できれば有効化します
(Kick = OAuth2.1 PKCE、ツイキャス = OAuth2.0)。

---

## ローカルでの動作確認 (ビルド前)

IPA を作らなくても、`docs/` をブラウザで開けば埋め込みと弾幕を確認できます。

```powershell
node .claude/serve.js   # http://localhost:5051 で docs/ を配信
```

`http://localhost:5051/` の動作確認ページで Twitch のチャンネル名を入れると、弾幕が流れます。

---

## 既知の制限

- **iOS ビルドは Windows 単体では不可** — 必ずクラウド Mac (本リポジトリの GitHub Actions) か実機 Mac が要ります。
- **無料 Apple ID**: 7 日失効・同時 3 アプリ。継続利用なら毎週再署名、または AltStore の利用を検討。
- **ニコ生ライブ**: 埋め込み非対応のため番組ページを直接表示 (純正コメントを利用)。
- **同時視聴数**: 端末性能次第で 3〜4 画面が実用上限。
- 各サービスの仕様変更で埋め込み/コメントが壊れることがあります。その場合は `docs/player.html`
  を直して push すれば、アプリ再ビルド不要で直ります。
