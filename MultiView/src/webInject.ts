import type {WebView} from 'react-native-webview';
import type {PlatformId} from './types';
import {adNetworkBlockerScript, platformAdBlockExtras} from './adblock';

export function escapeForInjectedString(value: string) {
  return value
    .replace(/\\/g, '\\\\')
    .replace(/'/g, "\\'")
    .replace(/\r?\n/g, ' ');
}

export function injectWebComment(webView: WebView | null, text: string) {
  if (!webView) {
    return;
  }
  const escaped = escapeForInjectedString(text);
  webView.injectJavaScript(`
    (function(){
      var text = '${escaped}';
      var inputSelectors = [
        'textarea[name=comment]',
        'textarea',
        'input[type=text]',
        '[contenteditable=true]',
        '#input #input',
        'yt-live-chat-text-input-field-renderer #input',
        '[data-testid*=chat][contenteditable=true]',
        '[data-testid*=message][contenteditable=true]',
        '.ProseMirror'
      ];
      var input = null;
      for (var i = 0; i < inputSelectors.length && !input; i++) {
        input = document.querySelector(inputSelectors[i]);
      }
      if (!input) return false;
      input.focus();
      if ('value' in input) {
        input.value = text;
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
      } else {
        input.textContent = text;
        try {
          input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
        } catch (e) {
          input.dispatchEvent(new Event('input', { bubbles: true }));
        }
      }
      var buttonSelectors = [
        'yt-live-chat-message-input-renderer #send-button button',
        '#send-button button',
        'button[aria-label*=Send]',
        'button[aria-label*=送信]',
        'button[type=submit]',
        '[role=button][aria-label*=Send]',
        '[role=button][aria-label*=送信]',
        '[data-testid*=send]',
        '[data-testid*=Send]',
        '.comment-post button',
        '.CommentPost button'
      ];
      var send = null;
      for (var j = 0; j < buttonSelectors.length && !send; j++) {
        send = document.querySelector(buttonSelectors[j]);
      }
      if (send) {
        send.click();
      } else {
        input.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', bubbles: true, cancelable: true}));
        input.dispatchEvent(new KeyboardEvent('keyup', {key: 'Enter', code: 'Enter', bubbles: true, cancelable: true}));
      }
      return true;
    })();
    true;
  `);
}

export const sourceBridgeScript = `
(function(){
  if (window.__multiViewURLBridge) true;
  window.__multiViewURLBridge = true;
  var last = '';
  var lastGestureAt = 0;
  function recentGesture(){ return Date.now() - lastGestureAt < 1600; }
  function post(url){
    try {
      var value = String(url || location.href || '');
      if (!value || value === last) return;
      last = value;
      window.ReactNativeWebView.postMessage(JSON.stringify({type:'streamURL', url:value}));
    } catch(e) {}
  }
  function postSoon(url){
    setTimeout(function(){ post(url); post(location.href); }, 80);
    setTimeout(function(){ post(location.href); }, 500);
  }
  ['pointerdown','touchstart','mousedown'].forEach(function(name){
    document.addEventListener(name, function(){ lastGestureAt = Date.now(); }, true);
  });
  document.addEventListener('click', function(event){
    lastGestureAt = Date.now();
    var node = event.target;
    while (node && node !== document && !(node.tagName && node.tagName.toLowerCase() === 'a')) node = node.parentNode;
    if (node && node.href) postSoon(node.href);
  }, true);
  ['pushState','replaceState'].forEach(function(name){
    var original = history[name];
    history[name] = function(){
      var result = original.apply(this, arguments);
      if (recentGesture()) postSoon(location.href);
      return result;
    };
  });
  window.addEventListener('popstate', function(){ if (recentGesture()) postSoon(location.href); });
  true;
})();
`;

// YouTube ページ専用の同接数スクレイパ。ytInitialData / ytInitialPlayerResponse は
// YouTube 以外(twitcasting/niconico 等)のページには存在しないため、
// platform === 'youtube' の Web フォールバック時のみ注入する(他PFでは 5 秒間隔の
// ポーリングと MutationObserver 内の呼び出しが無駄になるだけなので入れない)。
const youtubeViewerCountScraperScript = `function toViewerNumber(value){
      if (value == null) return null;
      var parsed = Number(String(value).replace(/[^0-9]/g, ''));
      return isFinite(parsed) && parsed >= 0 ? Math.round(parsed) : null;
    }
    function toPlainViewerNumber(value){
      if (value == null) return null;
      if (!/^\\s*[0-9][0-9,\\s\\u00a0]*\\s*$/.test(String(value))) return null;
      return toViewerNumber(value);
    }
    function parseJSONLike(value){
      try {
        if (typeof value === 'string') return JSON.parse(value);
        return value || null;
      } catch(e) {
        return null;
      }
    }
    function getYouTubeInitialData(){
      return parseJSONLike(window.ytInitialData);
    }
    function getYouTubeInitialPlayer(){
      return parseJSONLike(window.ytInitialPlayerResponse);
    }
    function isYouTubeLivePage(data){
      try {
        var player = getYouTubeInitialPlayer();
        var details = player && player.videoDetails;
        var liveDetails = player && player.microformat &&
          player.microformat.playerMicroformatRenderer &&
          player.microformat.playerMicroformatRenderer.liveBroadcastDetails;
        var liveIndicator = data && data.playerOverlays &&
          data.playerOverlays.playerOverlayRenderer &&
          data.playerOverlays.playerOverlayRenderer.liveIndicatorText;
        return Boolean(
          (details && (details.isLive === true || details.isLiveContent === true)) ||
          (liveDetails && liveDetails.isLiveNow === true) ||
          liveIndicator
        );
      } catch(e) {
        return false;
      }
    }
    function desktopViewerCountFromInitialData(data){
      try {
        var contents = data && data.contents && data.contents.twoColumnWatchNextResults &&
          data.contents.twoColumnWatchNextResults.results &&
          data.contents.twoColumnWatchNextResults.results.results &&
          data.contents.twoColumnWatchNextResults.results.results.contents;
        if (!Array.isArray(contents)) return null;
        for (var i = 0; i < contents.length; i += 1) {
          var renderer = contents[i] && contents[i].videoPrimaryInfoRenderer &&
            contents[i].videoPrimaryInfoRenderer.viewCount &&
            contents[i].videoPrimaryInfoRenderer.viewCount.videoViewCountRenderer;
          if (renderer && renderer.isLive === true) {
            var count = toViewerNumber(renderer.originalViewCount);
            if (count != null) return count;
          }
        }
      } catch(e) {}
      return null;
    }
    function mobileViewerCountFromInitialData(data){
      try {
        if (!isYouTubeLivePage(data)) return null;
        var contents = data && data.contents && data.contents.singleColumnWatchNextResults &&
          data.contents.singleColumnWatchNextResults.results &&
          data.contents.singleColumnWatchNextResults.results.results &&
          data.contents.singleColumnWatchNextResults.results.results.contents;
        if (!Array.isArray(contents)) return null;
        for (var i = 0; i < contents.length; i += 1) {
          var section = contents[i] && contents[i].slimVideoMetadataSectionRenderer;
          var sectionContents = section && section.contents;
          if (!Array.isArray(sectionContents)) continue;
          for (var j = 0; j < sectionContents.length; j += 1) {
            var info = sectionContents[j] && sectionContents[j].slimVideoInformationRenderer;
            var subtitles = [info && info.collapsedSubtitle, info && info.expandedSubtitle];
            for (var k = 0; k < subtitles.length; k += 1) {
              var runs = subtitles[k] && subtitles[k].runs;
              if (Array.isArray(runs) && runs.length > 1) {
                var count = toPlainViewerNumber(runs[0] && runs[0].text);
                if (count != null) return count;
              }
            }
          }
        }
      } catch(e) {}
      return null;
    }
    function youtubeViewerCountFromInitialData(){
      var data = getYouTubeInitialData();
      var desktopCount = desktopViewerCountFromInitialData(data);
      if (desktopCount != null) return desktopCount;
      return mobileViewerCountFromInitialData(data);
    }
    function postYouTubeViewerCount(){
      try {
        var count = youtubeViewerCountFromInitialData();
        if (count != null && window.ReactNativeWebView) {
          window.ReactNativeWebView.postMessage(JSON.stringify({type:'viewerCount', count:count}));
        }
      } catch(e) {}
    }`;

export function webFallbackScript(blockAds: boolean, platform: PlatformId) {
  // iOS パリティの広告/ポップアップ対策をまず注入する:
  //  - blockAds 時: 広告ドメインの iframe/script を DOM から剥がす
  //  - ニコ生: 快適視聴/プレミアム会員モーダルを隠す
  //  - Kick/Twitch: 埋め込みプレイヤーの tap を止める
  return `
  ${blockAds ? adNetworkBlockerScript : ''}
  ${platformAdBlockExtras(platform)}
  (function(){
    ${platform === 'youtube' ? youtubeViewerCountScraperScript : ''}
    ${
      platform === 'twitcasting'
        ? `
    function focusTwitCastingPlayer(){
      try {
        var playerRoot = document.querySelector('.tw-player-page-grid-player') ||
          document.querySelector('.tw-player-wrapper') ||
          document.querySelector('.tw-player') ||
          document.querySelector('video');
        if (!playerRoot) return;
        if (document.body) {
          document.documentElement.style.setProperty('background','#000','important');
          document.documentElement.style.setProperty('overflow','hidden','important');
          document.body.style.setProperty('background','#000','important');
          document.body.style.setProperty('margin','0','important');
          document.body.style.setProperty('overflow','hidden','important');
        }
        playerRoot.style.setProperty('position','fixed','important');
        playerRoot.style.setProperty('top','0','important');
        playerRoot.style.setProperty('left','0','important');
        playerRoot.style.setProperty('right','0','important');
        playerRoot.style.setProperty('bottom','0','important');
        playerRoot.style.setProperty('width','100vw','important');
        playerRoot.style.setProperty('height','100vh','important');
        playerRoot.style.setProperty('z-index','2147483647','important');
        playerRoot.style.setProperty('background','#000','important');
        document.querySelectorAll('.tw-player-wrapper,.tw-player,.tw-player__body').forEach(function(node){
          node.style.setProperty('width','100%','important');
          node.style.setProperty('height','100%','important');
          node.style.setProperty('max-width','none','important');
          node.style.setProperty('margin','0','important');
          node.style.setProperty('background','#000','important');
        });
        document.querySelectorAll('.tw-player-header,.tw-player-page__app-link,.tw-player-meta,.tw-player-page-grid-meta,.tw-player-page__mobile-tab').forEach(function(node){
          node.style.setProperty('display','none','important');
        });
        document.querySelectorAll('video').forEach(function(media){
          media.style.setProperty('width','100%','important');
          media.style.setProperty('height','100%','important');
          media.style.setProperty('object-fit','contain','important');
          media.setAttribute('playsinline','');
          media.setAttribute('webkit-playsinline','');
          try { var p = media.play && media.play(); if (p && p.catch) p.catch(function(){}); } catch(e) {}
        });
      } catch(e) {}
    }
    `
        : ''
    }
    function tame(){
      try {
        document.querySelectorAll('video,audio').forEach(function(media){
          media.setAttribute('playsinline','');
          media.setAttribute('webkit-playsinline','');
        });
      } catch(e) {}
      ${platform === 'twitcasting' ? 'focusTwitCastingPlayer();' : ''}
      ${
        blockAds
          ? `
      try {
        var selectors = ['[class*=ad-]','[id*=ad-]','[class*=banner]','[id*=banner]','[class*=popup]','[class*=modal]'];
        selectors.forEach(function(sel){
          document.querySelectorAll(sel).forEach(function(node){
            var text = (node.innerText || node.textContent || '').slice(0, 120);
            if (/広告|Ad|Premium|プレミアム|popup/i.test(text) || /ad|banner|popup|modal/i.test(node.className || node.id || '')) {
              node.style.setProperty('display','none','important');
            }
          });
        });
      } catch(e) {}
      `
          : ''
      }
    }
    tame();
    ${
      platform === 'youtube'
        ? `postYouTubeViewerCount();
    new MutationObserver(function(){
      tame();
      postYouTubeViewerCount();
    }).observe(document.documentElement, {childList:true, subtree:true});
    setInterval(postYouTubeViewerCount, 5000);`
        : `new MutationObserver(function(){
      tame();
    }).observe(document.documentElement, {childList:true, subtree:true});`
    }
    ${platform === 'twitcasting' ? 'setInterval(focusTwitCastingPlayer, 2000);' : ''}
    window.mvPlay=function(){
      document.querySelectorAll('video,audio').forEach(function(media){try{var p=media.play&&media.play();if(p&&p.catch)p.catch(function(){});}catch(e){}});
    };
    window.mvPause=function(){
      document.querySelectorAll('video,audio').forEach(function(media){try{media.pause();}catch(e){}});
    };
    window.mvSetVolume=function(v){
      var n=Math.max(0,Math.min(1,+v||0));
      document.querySelectorAll('video,audio').forEach(function(media){try{media.muted=n<=0;media.volume=n;}catch(e){}});
    };
    true;
  })();
  `;
}
