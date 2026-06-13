# YouTube HLS regression log

## Current restore target

- Restore the YouTube direct playback path to the b57-era InnerTube player request.
- Keep later non-playback fixes, especially chat continuation, all-message selection, emote/sticker token preservation, OAuth send support, Android UI, and shared danmaku work.
- The current stable video baseline is tagged as `stable-b63-youtube-video-hls`.
  - If a later comment-source change destabilizes YouTube playback, compare against or restore from this tag before changing HLS extraction again.

## Do not reintroduce

- CF Worker extraction for YouTube playback.
  - The previous `workers.dev` path was rejected because it was unreliable and returned server-side failures.
  - It must not be used as a YouTube HLS fallback or primary route.
- Manual HLS auth-material prompts.
  - The b59 path that surfaced Cookie / PO Token / Visitor Data requirements failed in real use.
  - Do not show a "YouTube bot check / HLS Cookie / PO Token" runtime path as the normal playback solution.
- Official iframe as the primary YouTube playback route.
  - iframe remains only as an existing fallback path.
  - It is not the target UX because it can show official UI, ads, and embed-forbidden errors.

## b57 HLS shape

- InnerTube `/youtubei/v1/player` request.
- iOS client first, Android client second.
- `contentPlaybackContext.html5Preference = HTML5_PREF_WANTS`.
- Accept `streamingData.hlsManifestUrl` when present.
- For live streams, do not accept the first progressive format before every b57 client has had a chance to return HLS. Current YouTube responses can return iOS progressive first and Android HLS second.
- If no HLS exists, use only AVPlayer/ExoPlayer-playable muxed formats and otherwise fall back quickly.

## Harness

- `MultiView/src/__tests__/youtubePlaybackHarness.test.ts` scans the playback runtime files.
- It fails if the rejected CF Worker or b59 auth-material prompt route is added back.
- The same harness also checks YouTube chat parity: when chat polling, high-volume queues, or image-only emote/sticker handling are changed, both Android/React Native and iOS/Swift paths must carry the matching fix.
- Dr.Maggot-style chat changes must keep the official `live_chat` DOM observer present on both Android/React Native and iOS/Swift, while preserving InnerTube polling as the stable base path.
- For user-requested YouTube playback/chat fixes, build both artifacts before handoff: Android APK via local Gradle/ADB and iOS IPA via Codemagic after commit/push.
