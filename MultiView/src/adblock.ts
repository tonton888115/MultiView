import {PlatformId} from './types';

// iOS の WebAdBlocker.swift (WKContentRuleList) と AppDelegate.swift の
// niconicoPopupBlockerScript / embeddedPlayerTouchShieldScript を Android(RN) の
// WebView に移植したもの。
//
// react-native-webview の onShouldStartLoadWithRequest はナビゲーション(iframe先頭
// 読込含む)しか拾えず、resource 単位の遮断 (Kotlin shouldInterceptRequest 相当) は
// 出来ない。そこで:
//   1. onShouldStartLoadWithRequest で広告ドメインへの遷移を拒否 (isAdBlockedURL)
//   2. 注入 JS で広告 iframe/script を DOM から継続的に剥がす (adNetworkBlockerScript)
//   3. ニコ生は快適視聴/プレミアム会員モーダルを隠す (niconicoPopupBlockerScript)
//   4. Kick/Twitch 埋め込みプレイヤーはタップを止める (embeddedPlayerTouchShieldScript)
// の四段で対応する。iOSの広告ドメイン一覧と同一順序を維持し、ハーネスで照合する。

// iOS WebAdBlocker.swift の if-domain 一覧と完全に一致させる。
export const adBlockDomains: ReadonlyArray<string> = [
  'doubleclick.net',
  'googlesyndication.com',
  'googleadservices.com',
  'adservice.google.com',
  'pagead2.googlesyndication.com',
  'ads.youtube.com',
  'imasdk.googleapis.com',
  'pubads.g.doubleclick.net',
  'securepubads.g.doubleclick.net',
  'amazon-adsystem.com',
  'adnxs.com',
  'adsystem.com',
  'taboola.com',
  'outbrain.com',
];

export function isAdBlockedURL(url: string | undefined | null): boolean {
  if (!url) {
    return false;
  }
  let host: string;
  try {
    host = new URL(url).hostname.toLowerCase();
  } catch {
    return false;
  }
  return adBlockDomains.some(domain => host === domain || host.endsWith('.' + domain));
}

// DOM レベルで広告 iframe/script/preload を継続的に剥がす。src のホスト名で判定し
// iOS の if-domain と同じ一覧を使うので動作の同等性が保たれる。
export const adNetworkBlockerScript = `(function(){
  var hosts = ${JSON.stringify(adBlockDomains)};
  function isAdSrc(src){
    if(!src) return false;
    try {
      var h = (new URL(src, location.href)).hostname.toLowerCase();
      for(var i=0;i<hosts.length;i++){
        var d = hosts[i];
        if (h === d || h.endsWith('.' + d)) return true;
      }
    } catch(e) {}
    return false;
  }
  function strip(){
    try {
      document.querySelectorAll('iframe').forEach(function(f){ if(isAdSrc(f.src)) f.remove(); });
      document.querySelectorAll('script[src]').forEach(function(s){ if(isAdSrc(s.src)) s.remove(); });
      document.querySelectorAll('link[rel="preload"][href],link[rel="prefetch"][href]').forEach(function(l){ if(isAdSrc(l.href)) l.remove(); });
    } catch(e) {}
  }
  strip();
  new MutationObserver(strip).observe(document.documentElement, { childList: true, subtree: true });
})();`;

// iOS AppDelegate.swift:386 niconicoPopupBlockerScript を移植。
// "快適視聴/プレミアム会員" モーダルを継続的に隠す。
export const niconicoPopupBlockerScript = `(function(){
  function hideComfortPopup(){
    var words = ['快適視聴してみませんか', '快適視聴', 'プレミアム会員'];
    var nodes = Array.prototype.slice.call(document.querySelectorAll('[role="dialog"], dialog, [class*="modal"], [class*="Modal"], [class*="popup"], [class*="Popup"], [class*="overlay"], [class*="Overlay"]'));
    nodes.forEach(function (node) {
      var text = node.innerText || node.textContent || '';
      if (words.some(function (word) { return text.indexOf(word) !== -1; })) {
        node.style.setProperty('display', 'none', 'important');
        node.style.setProperty('visibility', 'hidden', 'important');
        node.style.setProperty('pointer-events', 'none', 'important');
      }
    });
  }
  hideComfortPopup();
  new MutationObserver(hideComfortPopup).observe(document.documentElement, { childList: true, subtree: true });
})();`;

// iOS AppDelegate.swift:405 embeddedPlayerTouchShieldScript を移植。
// Kick/Twitch の埋め込みプレイヤー上の tap で本家サイトへ遷移するのを防ぐ。
export const embeddedPlayerTouchShieldScript = `(function(){
  var styleId = 'mv-embedded-player-touch-shield';
  function install(){
    if (!document.getElementById(styleId)) {
      var style = document.createElement('style');
      style.id = styleId;
      style.textContent = '#player iframe,#player video{pointer-events:none!important}';
      (document.head || document.documentElement).appendChild(style);
    }
  }
  install();
  new MutationObserver(install).observe(document.documentElement, { childList: true, subtree: true });
})();`;

// プラットフォーム固有の追加注入。iOSと同じ振り分けにする。
export function platformAdBlockExtras(platform: PlatformId): string {
  switch (platform) {
    case 'niconico':
      return niconicoPopupBlockerScript;
    case 'kick':
    case 'twitch':
      return embeddedPlayerTouchShieldScript;
    default:
      return '';
  }
}
