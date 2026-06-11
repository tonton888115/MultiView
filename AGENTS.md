# Project Notes for Agents

- Build iOS with Codemagic. Do not stop at "Windows cannot build iOS"; use `tools/codemagic-build.ps1`, which triggers the `ios-unsigned-ipa` workflow in `codemagic.yaml` and downloads the IPA.
- Codemagic builds the remote branch, not the local working tree. Commit and push the intended iOS changes before triggering the build, otherwise the IPA will be stale.
- The Codemagic token is expected at `%USERPROFILE%\.codemagic\token`. Do not print the token.
- For Android verification, use the connected physical device through ADB. Do not use an emulator unless the user explicitly asks for one.
- Local SDK/JDK downloads and generated artifacts belong under `.tools/` and `artifacts/`; do not commit them.
- Chat/danmaku behavior should follow the Dr.Maggot-style model: treat the official chat surface as the source of truth, preserve visible text plus emotes/stickers as tokens, and avoid silently dropping comments under high flow. For YouTube, prefer InnerTube live_chat renderers for reading because YouTube Data API `displayMessage` flattens or loses emoji/sticker image data; keep OAuth only for sending comments.
