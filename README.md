# MultiView

[English](README.en.md) | 日本語

MultiView は、Kick / Twitch / YouTube / ニコ生 / ツイキャスの配信を iPhone / iPad で同時視聴するための iOS アプリです。グリッド表示、1配信の拡大表示、ドラッグ並び替え、弾幕コメント、端末間引き継ぎに対応しています。

このアプリは個人利用のサイドロード前提です。各サービスの利用規約、API/OAuth条件、コンテンツ利用条件は各自で確認してください。

## ダウンロード

最新版の IPA は GitHub Releases から取得できます。

- [MultiView Releases](https://github.com/tonton888115/MultiView/releases)

## 推奨インストール

SideStore で LiveContainer を導入し、LiveContainer に MultiView の IPA を追加する運用を推奨します。

- [SideStore](https://sidestore.io)
- [SideStore GitHub](https://github.com/SideStore/SideStore)
- [LiveContainer GitHub](https://github.com/LiveContainer/LiveContainer)
- Windows で SideStore 導入を補助する場合: [iloader](https://github.com/nab138/iloader)

手順:

1. SideStore を入れる。
2. SideStore から LiveContainer を入れる。
3. Releases から `MultiView-...ipa` をダウンロードする。
4. LiveContainer の Apps から IPA を追加する。

## 主な機能

- フォロー / ランキング / 視聴 / 設定の4タブ
- グリッド同時視聴、縦1列表示、1配信の拡大表示
- iOSホーム画面風のドラッグ並び替え
- ニコ生風の右から左へ流れる弾幕
- Kick / Twitch / YouTube / ニコ生 / ツイキャスのコメント取得
- 対応サービスでのコメント投稿
- QR / クリップボードによる端末間引き継ぎ
- Wi-Fi / モバイル別の画質設定
- ギフト/通知演出の表示切替と通知音切替

## 対応サービス

| サービス | 映像 | 弾幕 | コメント投稿 |
|---|---|---|---|
| Twitch | Amazon IVS Player + fallback | 匿名受信 | 拡大時の公式チャット |
| Kick | Amazon IVS Player | Pusher受信 | OAuthログイン |
| YouTube | InnerTube HLSのみ（必要時はHLS Cookie/PO Token/Visitor Dataを設定） | InnerTube + OAuth | 拡大時の公式チャット |
| ツイキャス | ネイティブHLS | best-effort | OAuthログイン |
| ニコ生 | HLS + 純正コメント | 純正コメント + ギフト | Webログイン |

## OAuth / ログイン

コメント投稿や YouTube 弾幕には、サービスごとのログインや OAuth 設定が必要です。現状、OAuth の Client ID / Client Secret はアプリに同梱していません。設定画面から各自の Client ID を入力する構成です。

トークンは iOS Keychain に保存されます。Webログインが必要なサービスは、アプリ内 WebView の Cookie を使います。

YouTube の OAuth はコメント投稿用です。YouTube が未認証の player endpoint に `LOGIN_REQUIRED` を返す場合、映像の直接 HLS 取得には設定画面の HLS Cookie / PO Token / Visitor Data を使います。YouTube iframe / Web 埋め込みは、埋め込み禁止エラー、公式UI、広告表示が出るため Android/iOS の再生 fallback として使いません。

## セキュリティ / 公開について

- パスワード、Client Secret、アクセストークンはリポジトリに含めない設計です。
- リダイレクト中継ページ、Bundle ID、一部サービスの公開クライアント識別子は公開情報です。
- このアプリは各配信サービスの非公式クライアントです。第三者へ配布する場合は、商標、コンテンツ、API、OAuthの利用条件を確認してください。
- 現時点では明示的なオープンソースライセンスを設定していません。第三者の再利用を許可する場合は LICENSE を追加してください。

## App Store 公開について

現在の状態はサイドロード配布向けです。App Store に出すには、各サービスの映像・コメント・OAuth/API利用に関する権利確認、App Review 用の説明、プライバシーポリシー、App Store Connect のプライバシー回答、第三者SDKの privacy manifest / signature 確認が必要です。

## 開発者向け

アプリ本体は `MultiView/ios/MultiView/*.swift` の UIKit ネイティブ実装です。ビルド設定は `codemagic.yaml` と `tools/` にあります。
