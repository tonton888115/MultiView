# MultiView YouTube Extractor (Cloudflare Worker)

YouTube の生 URL 抽出を CF Worker 側で代行する。2026 年 YouTube は PoToken/SABR を
強制してきており、iOS 単独では URL を取得できないため、サーバ IP 経由で複数の
InnerTube クライアント (IOS / ANDROID / ANDROID_VR / TV) を回す。

成功率は完全ではないが、iframe フォールバックより「動画のみ」で再生できる確率が高い。
失敗した動画は iOS 側で従来通り iframe にフォールバックする。

無料枠: **100,000 req/日**、課金登録不要。

## デプロイ方法 (2 通り)

### 方法 A: Cloudflare ダッシュボードに貼り付け (一番簡単、Node 不要)

1. https://dash.cloudflare.com → サインアップ (無料)
2. 左メニュー **Workers & Pages** → **Create** → **Hello World**
3. Worker 名: `multiview-youtube` (任意) → **Deploy**
4. 直後の画面で **Edit code** → 既存の Worker コードを全消去
5. このリポジトリの [`src/index.js`](src/index.js) の内容を全部貼り付け
6. 右上 **Deploy**
7. デプロイ URL が表示される: `https://multiview-youtube.<your-subdomain>.workers.dev`

### 方法 B: wrangler CLI 経由 (Node.js が入っている人向け)

```powershell
# 一度だけ:
npm install -g wrangler
wrangler login   # ブラウザで Cloudflare 認証
# このディレクトリ (cloudflare-worker/youtube-extractor) で:
wrangler deploy
```

## 動作確認

ブラウザで以下を開く:

```
https://<your-worker>.workers.dev/health
→ {"ok":true,"clients":["IOS","ANDROID","ANDROID_VR","TVHTML5_SIMPLY_EMBEDDED_PLAYER"]}

https://<your-worker>.workers.dev/?v=dQw4w9WgXcQ
→ 200 で {url, type, isLive, client, title} か、
   502 で {error, sabrOnly, recommendIframe: true}
```

`recommendIframe: true` が返る動画 = サーバ側でも抽出不能 → iOS の iframe フォールバックに任せる。

## iOS 側との接続

デプロイした URL を MultiView の設定画面 (近日追加予定) に登録する。
- 設定 → **YouTube抽出 Worker URL** に貼る
- 抽出経路の優先順: ページ抽出 → CF Worker → iframe フォールバック

実装が間に合うまでは、CF Worker をテストして「動く動画 / 動かない動画」を把握しておく。

## トラブルシュート

- **`health` が出ない**: Worker のルートパスが間違っているか、デプロイ未完了。CF ダッシュボードでログを確認。
- **CORS エラー**: Worker は `Access-Control-Allow-Origin: *` を返すので、iOS からは問題なく呼べるはず。Web から呼ぶ場合のみ気にする。
- **すべての動画で 502**: PoToken 強制が厳しくなりすぎている可能性。CF Worker の IP が YouTube に bot 判定されているケースも。worker を再デプロイ (新 IP に変わる可能性) するか、地域変更のため別の CF アカウントでデプロイし直す。
- **`LOGIN_REQUIRED`**: ANDROID_VR クライアントで頻発。他クライアントに自動で切り替わるので無視して OK。
