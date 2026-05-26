# MultiView YouTube Extractor (Cloudflare Worker)

`youtubei.js` を使って YouTube の直接 googlevideo URL (VOD: muxed mp4 / live: HLS) を
返す CF Worker。iOS の AVPlayer がネイティブ再生できる URL なので、iframe / embed
の制約を完全に回避できる。

## ローカル検証済み (PC)

`tmp/yt-test/test.mjs` 相当の Node.js 版で確認済み:

| 動画 | 種類 | 結果 |
|---|---|---|
| Rick Astley (`dQw4w9WgXcQ`) | VOD | 360p mp4 / HEAD 200 / video/mp4 / 11.8 MB |
| Gangnam Style (`9bZkp7q19f0`) | VOD | 360p mp4 / HEAD 200 / video/mp4 / 15.6 MB |
| テレ朝NEWS24 (`coYw-eVU0Ks`) | Live | HLS manifest / HEAD 200 / application/vnd.apple.mpegurl |

→ AVPlayer が直接呑める URL であることを HEAD レスポンスで確認している。

## 無料デプロイ手順 (wrangler 経由、5分)

### ステップ 1: Node.js + wrangler

```powershell
cd C:\Users\rinng\projects\APP\cloudflare-worker\youtube-extractor
npm install                # youtubei.js + wrangler を取得
npx wrangler login         # ブラウザで Cloudflare 認証 (無料アカウント可)
```

### ステップ 2: デプロイ

```powershell
npx wrangler deploy
```

成功すると最後に URL が表示される:
```
Published multiview-youtube (XX.XX sec)
  https://multiview-youtube.<your-subdomain>.workers.dev
```

### ステップ 3: 動作確認

```
https://<your-worker>/health
→ {"ok":true,"version":"2026-05-27","engine":"youtubei.js"}

https://<your-worker>/?v=dQw4w9WgXcQ
→ {"url":"https://...googlevideo.com/...","kind":"mp4","isLive":false,"title":"Rick Astley - ...","quality":"360p"}

https://<your-worker>/?v=coYw-eVU0Ks    (テレ朝NEWS24 等のライブ)
→ {"url":"https://manifest.googlevideo.com/...","kind":"hls","isLive":true,"title":"..."}
```

## 無料枠

- 100,000 requests / day
- 課金登録不要
- バンドルサイズ ~1.4MB (cf-worker tier の 1MB 圧縮制限以下)

## トラブルシュート

- **`Decipher script returned an error`**: YouTube が player.js を変えた可能性。
  `npm update youtubei.js` で最新化して再デプロイ。
- **すべての動画で 502**: CF Worker の IP が YouTube に bot 判定された可能性。
  worker を別 region に再デプロイするか、後述の CF rule で UA を rotate する。
- **`generate_session_locally`**: 既に有効。CF Worker は origin が無いので
  PoToken 系の botguard は通常通り走る。
