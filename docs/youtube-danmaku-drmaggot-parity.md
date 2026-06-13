# YouTube danmaku Dr.Maggot parity task

## Stable baseline

- Do not change the current YouTube video/HLS acquisition path in this task.
- Video rollback anchor remains `stable-b63-youtube-video-hls`.
- This task is only for chat acquisition, duplicate suppression, and danmaku flow.

## Dr.Maggot findings

Local CRX inspection was done from the official Chrome extension package under `.tools/drmaggot/extracted`.

- Dr.Maggot does not rely on YouTube Data API or InnerTube as the danmaku source.
- It runs a content script on the official chat pages:
  - `youtube.com/live_chat?...`
  - `youtube.com/live_chat_replay?...`
- It observes the official chat DOM with `MutationObserver`.
- YouTube chat cells are read from official renderers, mainly:
  - `yt-live-chat-text-message-renderer`
  - `yt-live-chat-paid-message-renderer`
- Visible message contents are taken from `#message`.
- Official emoji/stamps are preserved by cloning or reading `.emoji` image nodes.
- For YouTube, the content script is inside the chat frame, but the danmaku canvas is attached to the parent official video player.
- Its lane model keeps row history, places a new bullet in the first safe row, and if every row is busy chooses the row whose current bullet is furthest left instead of dropping the comment.

Source of truth conclusion: for YouTube reading, the official live chat DOM should be treated as primary because it preserves exactly what the user sees, including YouTube-specific emoji/sticker nodes. InnerTube remains only a fallback for cases where the official DOM has not produced comments recently.

## Current defects

- YouTube comments can be duplicated because official DOM events and InnerTube/Data API events are both accepted at the same time.
- Deduplication includes token URLs, so the same visible comment can evade dedupe when one source supplies text and another source supplies image tokens.
- iOS still drip-feeds queued YouTube chat one item at a time using a spacing derived from poll interval and lane capacity. This produces the reported "one line at a time, then starts again from the top" feel.
- Android/React Native uses `Animated.timing` without explicit linear easing. React Native defaults can create acceleration/deceleration.
- Android/React Native lane selection depends on visible React state. During bursts, several comments can be assigned before state catches up, so they can reuse the same lane or overlap.
- Android/React Native lane selection only checks current front position, not a synchronous lane reservation for comments just emitted in the same drain cycle.

## Implementation plan

- Keep the current YouTube video path unchanged.
- Mark official YouTube DOM comments (`yt-dom:` IDs) as the primary source for a short active window.
- Suppress InnerTube/Data API YouTube comments while the official DOM source is active.
- Deduplicate by normalized visible identity:
  - platform
  - normalized author
  - normalized visible text when present
  - super chat/member metadata
  - image URLs only for image-only comments
- Increase duplicate window to cover official DOM plus fallback overlap.
- Android/React Native:
  - use `Easing.linear` for danmaku movement
  - add synchronous lane reservations at emit time
  - pick the first lane whose reserved/current front has moved away from the right edge
  - if all lanes are busy, pick the lane whose front is furthest left
- iOS:
  - mark official DOM as active and suppress fallback comments during that window
  - use the same visible-identity fingerprint
  - replace slow poll-interval drip with fast burst draining so high-flow chat does not crawl one line at a time
- Harness:
  - assert both Android/RN and iOS paths keep the official chat bridge
  - assert official DOM source priority exists on both paths
  - assert Android/RN uses linear easing and lane reservations
  - assert iOS no longer uses the old slow lane-capacity drip path

## Verification checklist

- TypeScript compile.
- Jest regression harness.
- Android release APK build.
- ADB install/test only when a physical device is visible.
- iOS Codemagic IPA build after commit/push when iOS sources change.
