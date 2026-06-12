# YouTube Live Chat / Playback Notes

## Do not repeat these failed approaches

- Do not use the YouTube iframe player as an Android/iOS playback path.
  - It can show embed restrictions, official controls, and ads.
  - Do not keep it as a fallback; retry direct HLS instead.
- Do not use the YouTube Data API as the read path for live comments.
  - It can return OAuth/API 403 errors.
  - `displayMessage` flattens or loses custom emoji/sticker image data.
  - OAuth remains for sending comments only.
- Do not treat buffering alone as the YouTube playback fix.
  - Buffer tuning helps stalls, but the resolver must first prefer playable HLS and avoid SABR-only outputs.
- Do not rely only on iOS InnerTube clients for direct playback.
  - Some iOS clients return `serverAbrStreamingUrl`/SABR without `hlsManifestUrl`.
  - Android InnerTube should be tried first for live HLS, then iOS fallback clients.
- Do not treat YouTube OAuth as the playback fix.
  - OAuth remains the comment-send path.
  - Direct playback may require the user's normal YouTube playback auth material: Cookie, PO Token, and Visitor Data.
- Do not ship or verify Android with debug APKs for this app.
  - Debug APKs can fail with `Unable to load script` if Metro is not running.
  - Use `assembleRelease` and verify the bundled release APK.

## Current expected implementation

- YouTube live chat reading uses InnerTube `live_chat/get_live_chat`.
- Initial chat HTML should prefer `https://www.youtube.com/live_chat?v=VIDEO_ID&is_popout=1`.
- The chat continuation must prefer the all-messages / live chat continuation over top chat.
- Comment parsing must preserve text runs plus custom emoji/sticker image tokens.
- If chat fetching fails, UI should show reconnecting state and retry. It must not expose raw HTTP 400/403 to users.
- Direct YouTube playback should prefer HLS returned by Android InnerTube client first, then iOS stable/current fallback clients.
- Attach configured YouTube HLS Cookie / PO Token / Visitor Data to InnerTube `player` requests.
- Generate `SAPISIDHASH` from configured Cookie when a SAPISID-family cookie is present.
- Iframe/Web playback is not a fallback for Android/iOS. Keep retrying direct HLS and surface a recoverable HLS state that tells the user when playback auth material is missing.

## Verification requirements before saying "works"

- Android: install release APK on a physical device through ADB.
- Android: test with a known currently live YouTube stream, not a saved/offline stream.
- Android: confirm video renders and comments/danmaku actually appear on-device.
- Android: check logcat for `FATAL`, `Unable to load script`, raw `HTTP 400/403`, and embed restriction errors.
- iOS: bump build number before Codemagic if the previous IPA name already exists.
- iOS: Codemagic must build the pushed commit, not only the local working tree.
