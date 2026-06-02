# MultiView

English | [日本語](README.md)

MultiView is an iOS app for watching Kick / Twitch / YouTube / Niconico Live / TwitCasting streams at the same time on iPhone or iPad. It supports grid viewing, focused playback, drag reordering, danmaku comments, and device-to-device handoff.

This is a personal-use sideloading app. Check each service's Terms of Service, API/OAuth terms, and content usage rules before using or distributing it.

## Download

Download the latest IPA from GitHub Releases.

- [MultiView Releases](https://github.com/tonton888115/MultiView/releases)

## Recommended Install

The recommended setup is SideStore + LiveContainer: install LiveContainer through SideStore, then add the MultiView IPA to LiveContainer.

- [SideStore](https://sidestore.io)
- [SideStore GitHub](https://github.com/SideStore/SideStore)
- [LiveContainer GitHub](https://github.com/LiveContainer/LiveContainer)
- Optional Windows helper: [iloader](https://github.com/nab138/iloader)

Steps:

1. Install SideStore.
2. Install LiveContainer through SideStore.
3. Download `MultiView-...ipa` from Releases.
4. Add the IPA from LiveContainer's Apps screen.

## Features

- Four tabs: Following / Ranking / Watch / Settings
- Grid multi-view, stacked single-column view, and focused playback
- iOS Home Screen-style drag reordering
- Niconico-style right-to-left danmaku comments
- Comment receiving for Kick / Twitch / YouTube / Niconico Live / TwitCasting
- Comment posting where supported
- QR / clipboard handoff between devices
- Separate quality settings for Wi-Fi and cellular
- Gift/notification effect and sound toggles

## Supported Services

| Service | Video | Danmaku | Comment posting |
|---|---|---|---|
| Twitch | Amazon IVS Player + fallback | Anonymous receiving | Official chat in focus |
| Kick | Amazon IVS Player | Pusher receiving | OAuth login |
| YouTube | InnerTube HLS + iframe fallback | Data API + OAuth | Official chat in focus |
| TwitCasting | Native HLS | best-effort | OAuth login |
| Niconico Live | HLS + native comments | Native comments + gifts | Web login |

## OAuth / Login

Comment posting and YouTube danmaku require service-specific login or OAuth configuration. Currently, OAuth Client IDs / Client Secrets are not bundled in the app. Users enter their own Client IDs in Settings.

Tokens are stored in the iOS Keychain. Services that require web login use cookies from the in-app WebView.

## Security / Publishing

- Passwords, Client Secrets, and access tokens are not committed by design.
- Redirect bridge pages, the Bundle ID, and some public service client identifiers are public information.
- This app is an unofficial client for the supported streaming services. Before distributing it to others, check trademark, content, API, and OAuth terms.
- No explicit open-source license is selected yet. Add a LICENSE before granting third parties reuse rights.

## App Store Distribution

The current project is designed for sideload distribution. App Store submission still requires checking rights and permissions for each service's video, comments, OAuth/API flows, and marks, plus App Review notes, a privacy policy, App Store Connect privacy answers, and third-party SDK privacy manifest/signature compliance.

## Development

The app is implemented as native UIKit code under `MultiView/ios/MultiView/*.swift`. Build configuration lives in `codemagic.yaml` and `tools/`.
