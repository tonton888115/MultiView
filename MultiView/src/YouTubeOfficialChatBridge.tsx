import React, {useEffect, useState} from 'react';
import {StyleSheet} from 'react-native';
import {WebView, type WebViewMessageEvent} from 'react-native-webview';
import {makeChatEvent, textTokens} from './danmaku';
import {desktopUserAgent, resolveLiveYouTubeVideoID, youtubeVideoId} from './playback';
import type {ChatEvent, DanmakuToken, StreamItem} from './types';

type Props = {
  stream: StreamItem;
  onEvent: (event: ChatEvent) => void;
  onStatus: (message: string) => void;
};

type BridgeMessage =
  | {
      type: 'status';
      message?: string;
    }
  | {
      type: 'chat';
      id?: string;
      author?: string;
      text?: string;
      tokens?: DanmakuToken[];
      superInfo?: string;
    };

export function YouTubeOfficialChatBridge({stream, onEvent, onStatus}: Props) {
  const [videoId, setVideoId] = useState<string | null>(() => youtubeVideoId(stream.channel));

  useEffect(() => {
    let cancelled = false;
    const direct = youtubeVideoId(stream.channel);
    if (direct) {
      setVideoId(direct);
      return () => {
        cancelled = true;
      };
    }
    setVideoId(null);
    resolveLiveYouTubeVideoID(stream.channel)
      .then(resolved => {
        if (!cancelled) {
          setVideoId(resolved);
        }
      })
      .catch(() => {
        if (!cancelled) {
          onStatus('YouTube公式チャット待機中');
        }
      });
    return () => {
      cancelled = true;
    };
  }, [onStatus, stream.channel]);

  if (!videoId) {
    return null;
  }

  const source = {uri: `https://www.youtube.com/live_chat?v=${encodeURIComponent(videoId)}&is_popout=1`};

  return (
    <WebView
      source={source}
      userAgent={desktopUserAgent}
      javaScriptEnabled
      domStorageEnabled
      sharedCookiesEnabled
      thirdPartyCookiesEnabled
      injectedJavaScript={youtubeOfficialChatObserverScript}
      onMessage={(event: WebViewMessageEvent) => {
        const message = parseBridgeMessage(event.nativeEvent.data);
        if (!message) {
          return;
        }
        if (message.type === 'status') {
          if (message.message) {
            onStatus(message.message);
          }
          return;
        }
        const tokens = sanitizeTokens(message.tokens);
        const tokenText = tokens.map(token => (token.kind === 'text' ? token.text : token.alt ?? '')).join('');
        const text = (message.text ?? tokenText).trim() || (tokens.some(token => token.kind === 'image') ? 'emoji' : '');
        if (!text && !message.superInfo) {
          return;
        }
        onEvent(makeChatEvent(
          'youtube',
          `yt-dom:${message.id || `${Date.now()}:${Math.random()}`}`,
          text || message.superInfo || '',
          tokens.length ? tokens : textTokens(text || message.superInfo || ''),
          message.author,
          message.superInfo,
        ));
      }}
      onError={() => onStatus('YouTube公式チャット再接続中')}
      style={styles.hiddenWebView}
    />
  );
}

function parseBridgeMessage(raw: string): BridgeMessage | null {
  try {
    const parsed = JSON.parse(raw) as BridgeMessage;
    if (parsed?.type === 'status' || parsed?.type === 'chat') {
      return parsed;
    }
  } catch {
    return null;
  }
  return null;
}

function sanitizeTokens(tokens: DanmakuToken[] | undefined): DanmakuToken[] {
  if (!Array.isArray(tokens)) {
    return [];
  }
  const sanitized: DanmakuToken[] = [];
  tokens.forEach(token => {
    if (token?.kind === 'text') {
      const text = String(token.text ?? '');
      if (text) {
        sanitized.push({kind: 'text', text});
      }
      return;
    }
    if (token?.kind === 'image') {
      const url = String(token.url ?? '');
      if (url) {
        sanitized.push({kind: 'image', url, alt: token.alt ? String(token.alt) : 'emoji'});
      }
    }
  });
  return sanitized;
}

export const youtubeOfficialChatObserverScript = `
(function() {
  if (window.__mvYouTubeOfficialChatObserverInstalled) {
    return true;
  }
  window.__mvYouTubeOfficialChatObserverInstalled = true;
  var seen = new Set();
  var seenOrder = [];
  var maxSeen = 20000;
  var keepSeen = 12000;
  var rendererSelector = [
    'yt-live-chat-text-message-renderer',
    'yt-live-chat-paid-message-renderer',
    'yt-live-chat-paid-sticker-renderer',
    'yt-live-chat-membership-item-renderer',
    'yt-live-chat-sponsorships-gift-purchase-announcement-renderer',
    'yt-live-chat-sponsorships-gift-redemption-announcement-renderer',
    'yt-live-chat-gift-membership-received-renderer'
  ].join(',');

  function post(payload) {
    try {
      window.ReactNativeWebView.postMessage(JSON.stringify(payload));
    } catch (error) {}
  }

  function visibleText(node) {
    if (!node) { return ''; }
    return String(node.innerText || node.textContent || '').replace(/\\s+/g, ' ').trim();
  }

  function absoluteURL(value) {
    if (!value) { return ''; }
    var raw = String(value);
    if (raw.indexOf('//') === 0) { return 'https:' + raw; }
    return raw;
  }

  function srcFromSet(value) {
    if (!value) { return ''; }
    var best = '';
    var bestScore = -1;
    String(value).split(',').forEach(function(part) {
      var bits = part.trim().split(/\\s+/);
      var url = bits[0] || '';
      var score = 0;
      if (bits[1]) {
        if (bits[1].indexOf('w') > -1) {
          score = parseInt(bits[1], 10) || 0;
        } else if (bits[1].indexOf('x') > -1) {
          score = Math.round((parseFloat(bits[1]) || 0) * 1000);
        }
      }
      if (url && score >= bestScore) {
        best = url;
        bestScore = score;
      }
    });
    return best;
  }

  function imageURL(img) {
    return absoluteURL(img.currentSrc || img.src || img.getAttribute('data-thumb') || srcFromSet(img.getAttribute('srcset')));
  }

  function pushText(tokens, value) {
    var text = String(value || '').replace(/\\s+/g, ' ');
    if (!text) { return; }
    var last = tokens[tokens.length - 1];
    if (last && last.kind === 'text') {
      last.text += text;
    } else {
      tokens.push({kind: 'text', text: text});
    }
  }

  function collectTokens(node, tokens) {
    if (!node) { return; }
    if (node.nodeType === Node.TEXT_NODE) {
      pushText(tokens, node.nodeValue || '');
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) { return; }
    var element = node;
    if (element.matches && element.matches('img')) {
      var url = imageURL(element);
      if (url) {
        tokens.push({kind: 'image', url: url, alt: element.alt || element.getAttribute('aria-label') || 'emoji'});
      }
      return;
    }
    Array.prototype.forEach.call(element.childNodes || [], function(child) {
      collectTokens(child, tokens);
    });
  }

  function normalizeTokens(tokens) {
    var normalized = [];
    tokens.forEach(function(token) {
      if (token.kind === 'text') {
        pushText(normalized, token.text);
      } else if (token.kind === 'image' && token.url) {
        normalized.push(token);
      }
    });
    return normalized.filter(function(token) {
      return token.kind === 'image' || String(token.text || '').trim();
    });
  }

  function parseRenderer(element) {
    var tokens = [];
    Array.prototype.forEach.call(element.querySelectorAll('#sticker img, #content img.emoji'), function(img) {
      var url = imageURL(img);
      if (url) {
        tokens.push({kind: 'image', url: url, alt: img.alt || img.getAttribute('aria-label') || 'sticker'});
      }
    });
    var messageRoot = element.querySelector('#message');
    if (messageRoot) {
      collectTokens(messageRoot, tokens);
    } else {
      ['#header-primary-text', '#header-subtext', '#primary-text', '#subtext', '#body', '#content'].forEach(function(selector) {
        var root = element.querySelector(selector);
        if (root) {
          collectTokens(root, tokens);
        }
      });
    }
    tokens = normalizeTokens(tokens);
    var author = visibleText(element.querySelector('#author-name'));
    var superInfo = visibleText(element.querySelector('#purchase-amount, #purchase-amount-chip, #content #purchase-amount'));
    var text = tokens.map(function(token) {
      return token.kind === 'text' ? token.text : (token.alt || '');
    }).join('').replace(/\\s+/g, ' ').trim();
    if (!text && tokens.some(function(token) { return token.kind === 'image'; })) {
      text = 'emoji';
    }
    if (!text && !superInfo) { return null; }
    var id = element.id || element.getAttribute('data-id') || [author, text, superInfo, tokens.map(function(token) { return token.url || token.text || ''; }).join('|')].join('|');
    return {type: 'chat', id: id, author: author, text: text, tokens: tokens, superInfo: superInfo || undefined};
  }

  function remember(id) {
    if (!id || seen.has(id)) { return false; }
    seen.add(id);
    seenOrder.push(id);
    if (seenOrder.length > maxSeen) {
      var removed = seenOrder.splice(0, seenOrder.length - keepSeen);
      removed.forEach(function(value) { seen.delete(value); });
    }
    return true;
  }

  function scan(root) {
    if (!root || !root.querySelectorAll) { return; }
    if (root.matches && root.matches(rendererSelector)) {
      var own = parseRenderer(root);
      if (own && remember(own.id)) { post(own); }
    }
    Array.prototype.forEach.call(root.querySelectorAll(rendererSelector), function(element) {
      var parsed = parseRenderer(element);
      if (parsed && remember(parsed.id)) { post(parsed); }
    });
  }

  function preferAllMessages() {
    var text = document.body ? visibleText(document.body).toLowerCase() : '';
    if (!text) { return; }
    var buttons = Array.prototype.slice.call(document.querySelectorAll('button, yt-icon-button, tp-yt-paper-item, ytd-menu-service-item-renderer'));
    var topSelected = buttons.some(function(button) {
      var label = visibleText(button).toLowerCase() + ' ' + String(button.getAttribute('aria-label') || '').toLowerCase();
      return label.indexOf('top chat') >= 0 || label.indexOf('トップチャット') >= 0;
    });
    if (!topSelected) { return; }
    var menuButton = document.querySelector('#menu-button button, yt-sort-filter-sub-menu-renderer button, button[aria-label*="chat"], button[aria-label*="チャット"]');
    if (menuButton) { try { menuButton.click(); } catch (error) {} }
    setTimeout(function() {
      Array.prototype.forEach.call(document.querySelectorAll('tp-yt-paper-item, ytd-menu-service-item-renderer, yt-formatted-string'), function(item) {
        var label = visibleText(item).toLowerCase();
        var isTop = label.indexOf('top chat') >= 0 || label.indexOf('トップチャット') >= 0;
        var isAll = label.indexOf('live chat') >= 0 || label.indexOf('all messages') >= 0 || label.indexOf('すべてのメッセージ') >= 0 || (label.indexOf('チャット') >= 0 && !isTop);
        if (isAll && !isTop) {
          try { item.click(); } catch (error) {}
        }
      });
    }, 250);
  }

  var observer = new MutationObserver(function(mutations) {
    mutations.forEach(function(mutation) {
      Array.prototype.forEach.call(mutation.addedNodes || [], scan);
    });
  });
  observer.observe(document.documentElement || document, {childList: true, subtree: true});
  setInterval(function() { scan(document); }, 2000);
  setTimeout(function() { scan(document); post({type: 'status', message: 'YouTube公式チャット監視中'}); }, 800);
  setInterval(preferAllMessages, 5000);
  preferAllMessages();
  true;
})();
`;

const styles = StyleSheet.create({
  hiddenWebView: {
    position: 'absolute',
    width: 1,
    height: 1,
    left: -2,
    top: -2,
    opacity: 0.01,
  },
});
