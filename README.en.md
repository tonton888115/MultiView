# MultiView — watch multiple live streams at once (iOS / sideload)

English ｜ [日本語](README.md)

An iOS app to watch **Kick / Twitch / YouTube / Niconico Live / TwitCasting** streams
**simultaneously in a grid**, with chat shown as **Niconico-style danmaku** (comments scrolling
right→left over the video). Each service plays through a **native player**, with focus/zoom,
drag-to-reorder, and **device-to-device handoff (QR)**.

You can develop entirely on **Windows**, build an **unsigned IPA on a cloud Mac (Codemagic)**,
and install it via **LiveContainer** (recommended) or Sideloadly.

Repository: **https://github.com/tonton888115/MultiView** (public)

> ⚠️ A personal-use sideloading tool. You are responsible for complying with each service's Terms of Service.

---

## Features

- **4 bottom tabs**: Following / Ranking / Watch / Settings
- **Watch tab**: grid multi-view. Tap **⤢** on a cell to focus one stream, long-press to reorder, **×** to remove
- **Native playback**: a dedicated player per service (YouTube via HLS extraction; Kick/Twitch/TwitCasting via HLS; Niconico via the program-page HLS + comment WebSocket)
- **Danmaku**: Niconico-style right→left comments (toggle/speed/opacity/font size/max lines/max length). Niconico also renders gift effects
- **Posting comments**: from an in-app field where supported; otherwise log in via the official chat shown in the focused view
- **Device handoff**: the QR button in the Watch tab carries your open tabs between iPad ↔ iPhone (QR scan or clipboard; no server)
- **Low-latency tuning**: Kick rewrites the IVS playlist to ride closer to live; Niconico has a low-latency toggle
- **Quality**: separate high/economy for Wi-Fi vs cellular

---

## Supported services

| Service | Video | Danmaku (right→left) | Post comment |
|---|---|---|---|
| Twitch | ✅ native HLS | ✅ anonymous | ✅ official chat in focus (login) |
| Kick | ✅ native HLS (low-latency) | ✅ Pusher | ✅ native (OAuth login) |
| YouTube | ✅ HLS extraction | △ needs Data API + OAuth | ✅ official live chat in focus (login) |
| TwitCasting | ✅ native HLS | ⚠️ best-effort | ✅ native (OAuth login) |
| Niconico | ✅ HLS + native comments | native comments + gifts | ✅ native (needs user_session login) |

---

## Develop & build (Windows)

- The app itself is **`MultiView/ios/MultiView/*.swift`** (native UIKit). It reuses an RN project skeleton for the build/pods, but the UI is fully native.
- Building iOS needs a Mac, so an unsigned IPA is produced on **Codemagic** (cloud Mac). GitHub Actions is not used.

```powershell
# 1. Commit & push to main
git add -A; git commit -m "your change"; git push origin main

# 2. Build on Codemagic; download the IPA to artifacts and iCloud
#    (output is versioned: MultiView-<version>-b<build>.ipa)
tools\codemagic-build.ps1
```

> Save your Codemagic API token at `~/.codemagic/token` (the script builds the `ios-unsigned-ipa` workflow in `codemagic.yaml`).

---

## Install (iloader + LiveContainer recommended)

**LiveContainer** is recommended: it avoids the free Apple ID "7-day expiry / 3-app limit" friction and makes re-installs easy.

1. **Get LiveContainer**: install it via [SideStore](https://sidestore.io) or [AltStore](https://altstore.io). On Windows, [**iloader**](https://github.com/nab138/iloader) makes this easy.
2. **Add the IPA**: send `MultiView-<version>-b<build>.ipa` to the iPhone (e.g. iCloud Drive) and import it in LiveContainer via **Apps → +**. If it already exists, choose **replace** and keep the container data (your login cookies).
3. Launch → confirm the version in the Settings footer: **`MultiView x.y.z (build N)`**.

> 💡 **Always version the filename** (e.g. `MultiView-1.1.12-b21.ipa`). A generic `MultiView.ipa` can be served from an iPhone-side cache, making an update look like "nothing changed". `tools\codemagic-build.ps1` auto-versions the name and prunes old IPAs.
>
> **Alternative**: install directly with [Sideloadly](https://sideloadly.io). A free Apple ID signature expires in 7 days, max 3 apps.

---

## OAuth login (bring your own Client ID)

In-app comment posting and YouTube danmaku require **registering your own OAuth app** per service.
**No Client ID/Secret is bundled** in the app (defaults are empty). Register on each developer
console and **enter your own Client ID in Settings**.

- The default redirect URI points to the author's GitHub Pages bounce pages (`https://tonton888115.github.io/MultiView/*.html`, static pages that just return the code to `multiview://`). For independent use, **host your own bounce pages** and change the redirect URI.
- YouTube uses an iOS client ID (reverse-domain redirect). Kick uses OAuth 2.1 PKCE; TwitCasting uses OAuth 2.0.
- Tokens are stored in the iOS **Keychain**.

---

## YouTube extraction Cloudflare Worker (optional)

YouTube live/DVR HLS manifests come from the Worker in **`cloudflare-worker/youtube-extractor`**.
By default it uses the author's Worker (`multiview.rinngo0626.workers.dev`); **heavy third-party use
consumes the author's free tier (100k req/day)**. To run your own:

```sh
cd cloudflare-worker/youtube-extractor
npm i && npx wrangler deploy   # deploy to your own *.workers.dev
```

Then change `extractionWorkerURL` in `Players.swift` to your Worker URL. The Worker contains no
secrets (uses InnerTube, no API key).

---

## Security / publishing

- ✅ **No hardcoded secrets**: no API keys, passwords, or tokens in the code. OAuth Client ID/Secret are **user-entered** (empty by default); access tokens live in the Keychain. The Worker has no secrets either.
- ⚠️ **Personal identifiers exposed (not secrets)**: the Worker URL (`*.rinngo0626.workers.dev`), the redirect bounce pages (`tonton888115.github.io`), and the Bundle ID (`com.rinng.multiview`). These are already public via the public repo.
- ⚠️ **If other people use it**: (1) YouTube playback hits the author's Worker (quota) → deploy your own; (2) OAuth needs each user's own Client ID; (3) sharing the redirect bounce pages means the OAuth code transits the author's static page briefly (self-host for independence).
- Bottom line: **publishing the source is safe** (no secret leakage). If you don't want others using the shared Worker / bounce pages, tell them to deploy their own and use their own Client IDs.

---

## Known limitations

- **iOS builds aren't possible on Windows alone** — a cloud Mac (Codemagic) is required.
- **Free Apple ID**: signatures expire in 7 days. LiveContainer keeps re-install overhead low.
- **YouTube danmaku** needs the Data API + OAuth (viewing and chat input work without it).
- **Kick latency**: the official app uses Amazon IVS's dedicated player (~2s). This app uses AVPlayer + standard HLS, so ~5s is the practical floor (already reduced via playlist rewriting).
- Comfortable multi-view is **3–4 streams**, depending on device performance.
- Streams/chat can break when a site changes its internals.
