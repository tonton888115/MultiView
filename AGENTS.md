# Project Notes for Agents

- Build iOS with Codemagic. Do not stop at "Windows cannot build iOS"; use `tools/codemagic-build.ps1`, which triggers the `ios-unsigned-ipa` workflow in `codemagic.yaml` and downloads the IPA.
- Codemagic builds the remote branch, not the local working tree. Commit and push the intended iOS changes before triggering the build, otherwise the IPA will be stale.
- The Codemagic token is expected at `%USERPROFILE%\.codemagic\token`. Do not print the token.
- From a Claude cloud session (no Codemagic token, and the Claude GitHub integration cannot run `workflow_dispatch`), build with GitHub Actions instead: bump `CURRENT_PROJECT_VERSION`, update `.github/ios-build-request`, commit without `[skip ci]` (GitHub skips push-triggered runs when the message contains it), and push. `.github/workflows/ios-ipa.yml` then builds the pushed branch and uploads the `MultiView-unsigned-ipa` artifact (`MultiView-<version>-b<build>.ipa`, kept 1 day). Track it with the GitHub MCP `actions_list` / `actions_get`.
- Cloud sessions cannot reach iCloud Drive. On the Windows PC, `tools/github-ipa-download.ps1` (needs `gh auth login`; `-Wait` waits for a running build) downloads the latest build of the current branch into `artifacts\` and mirrors it to iCloud Drive Downloads, like `tools/codemagic-build.ps1`.
- For Android verification, use the connected physical device through ADB. Do not use an emulator unless the user explicitly asks for one.
- Local SDK/JDK downloads and generated artifacts belong under `.tools/` and `artifacts/`; do not commit them.
- Chat/danmaku behavior should follow the Dr.Maggot-style model: treat the official chat surface as the source of truth, preserve visible text plus emotes/stickers as tokens, and avoid silently dropping comments under high flow. For YouTube, prefer InnerTube live_chat renderers for reading because YouTube Data API `displayMessage` flattens or loses emoji/sticker image data; keep OAuth only for sending comments.
