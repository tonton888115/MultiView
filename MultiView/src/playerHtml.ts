import { WEBVIEW_BASE_URL } from './config';
import { DanmakuSettings, Settings, Stream } from './types';

export interface PlayerConfig {
  platform: 'kick' | 'twitch' | 'youtube' | 'twitcasting';
  channel: string;
  chat: boolean;
  proxy: string;
  parent: string;
  danmaku: DanmakuSettings;
}

export function playerConfigFor(stream: Stream, settings: Settings): PlayerConfig {
  return {
    platform: stream.platform as PlayerConfig['platform'],
    channel: stream.channel.trim(),
    chat: settings.showChat,
    proxy: settings.proxyUrl.trim(),
    parent: WEBVIEW_BASE_URL.replace(/^https?:\/\//, ''),
    danmaku: settings.danmaku,
  };
}

// Safe to embed inside a <script> tag.
function jsonForScript(value: unknown): string {
  return JSON.stringify(value).replace(/</g, '\\u003c');
}

// Twitch chat embed (with input + login) wrapped so parent matches our base origin.
export function buildTwitchChatHtml(channel: string, parent: string): string {
  const ch = encodeURIComponent(channel);
  return `<!doctype html>
<html lang="ja"><head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1" />
<style>html,body{margin:0;padding:0;width:100%;height:100%;background:#18181b;overflow:hidden}
iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
</head><body>
<iframe src="https://www.twitch.tv/embed/${ch}/chat?parent=${parent}&darkpopout=true"
  sandbox="allow-storage-access-by-user-activation allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox allow-modals allow-forms"></iframe>
</body></html>`;
}

// YouTube live chat embed (with input + login). Needs embed_domain to match our origin.
export function buildYouTubeChatHtml(videoId: string, parent: string): string {
  const v = encodeURIComponent(videoId);
  return `<!doctype html>
<html lang="ja"><head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1" />
<style>html,body{margin:0;padding:0;width:100%;height:100%;background:#fff;overflow:hidden}
iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
</head><body>
<iframe src="https://www.youtube.com/live_chat?v=${v}&embed_domain=${parent}"></iframe>
</body></html>`;
}

export function buildPlayerHtml(config: PlayerConfig): string {
  const cfg = jsonForScript(config);
  return `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no" />
<style>
  html, body { margin:0; padding:0; width:100%; height:100%; background:#000; overflow:hidden; }
  #player, #player iframe { position:absolute; inset:0; width:100%; height:100%; border:0; }
  #danmaku { position:fixed; inset:0; overflow:hidden; pointer-events:none; z-index:10; }
  .cmt {
    position:absolute; left:100%; top:0; white-space:nowrap;
    color:#fff; font-family:"Hiragino Kaku Gothic ProN","Yu Gothic",sans-serif;
    font-weight:700; line-height:1.2;
    text-shadow:-1px -1px 0 #000,1px -1px 0 #000,-1px 1px 0 #000,1px 1px 0 #000;
    will-change:transform;
  }
  #msg { position:absolute; left:0; right:0; bottom:0; color:#bbb;
    background:rgba(0,0,0,0.6); font-family:sans-serif; font-size:12px; padding:6px 10px;
    z-index:11; text-align:center; }
</style>
</head>
<body>
<div id="player"></div>
<div id="danmaku"></div>
<div id="msg" style="display:none"></div>
<script>
(function () {
  'use strict';
  var CFG = ${cfg};
  var D = CFG.danmaku || {};
  var playerEl = document.getElementById('player');
  var danmakuEl = document.getElementById('danmaku');
  var msgEl = document.getElementById('msg');

  function showMsg(t){ msgEl.textContent = t; msgEl.style.display = 'block'; }
  function viaProxy(u){ return CFG.proxy ? CFG.proxy + encodeURIComponent(u) : u; }

  // ---- embed ----
  function embedUrl(){
    var ch = encodeURIComponent(CFG.channel);
    if (CFG.platform === 'twitch')
      return 'https://player.twitch.tv/?channel=' + ch + '&parent=' + CFG.parent + '&muted=true&autoplay=true';
    if (CFG.platform === 'kick')
      return 'https://player.kick.com/' + ch + '?autoplay=true&muted=true';
    if (CFG.platform === 'youtube')
      return 'https://www.youtube.com/embed/' + ch + '?autoplay=1&mute=1&playsinline=1';
    if (CFG.platform === 'twitcasting')
      return 'https://twitcasting.tv/' + ch + '/embeddedplayer/live?auto_play=true';
    return '';
  }
  function mountPlayer(){
    var url = embedUrl();
    if (!url){ showMsg('未対応: ' + CFG.platform); return; }
    var f = document.createElement('iframe');
    f.src = url;
    f.allow = 'autoplay; fullscreen; encrypted-media; picture-in-picture';
    f.setAttribute('allowfullscreen','true');
    f.setAttribute('scrolling','no');
    playerEl.appendChild(f);
  }

  // ---- danmaku filtering (Dr.Maggot-style) ----
  var ngWords = (D.ngWords || []).map(function(w){ return String(w).toLowerCase(); });
  var ngUsers = (D.ngUsers || []).map(function(u){ return String(u).toLowerCase(); });
  function blocked(text, user){
    if (!text) return true;
    if (D.maxLength && text.length > D.maxLength) return true;
    var lt = text.toLowerCase();
    for (var i=0;i<ngWords.length;i++){ if (ngWords[i] && lt.indexOf(ngWords[i]) !== -1) return true; }
    if (user){ var lu = String(user).toLowerCase(); for (var j=0;j<ngUsers.length;j++){ if (ngUsers[j] === lu) return true; } }
    return false;
  }

  // ---- danmaku engine ----
  function Danmaku(root){
    this.root = root;
    this.fontSize = D.fontSize || 20;
    this.laneHeight = Math.round(this.fontSize * 1.5);
    this.speed = D.speed || 0.13;
    this.opacity = (D.opacity == null) ? 0.9 : D.opacity;
    this.maxLines = D.maxLines || 0;
    this.lanes = [];
    this.recompute();
    var self = this;
    window.addEventListener('resize', function(){ self.recompute(); });
  }
  Danmaku.prototype.recompute = function(){
    this.w = this.root.clientWidth || window.innerWidth;
    this.h = this.root.clientHeight || window.innerHeight;
    var fit = Math.max(1, Math.floor(this.h / this.laneHeight));
    var count = this.maxLines ? Math.min(this.maxLines, fit) : fit;
    if (count !== this.lanes.length) this.lanes = new Array(count).fill(0);
  };
  Danmaku.prototype.emit = function(text, color, user){
    if (blocked(text, user)) return;
    var now = performance.now(), lane = -1;
    for (var i=0;i<this.lanes.length;i++){ if (this.lanes[i] <= now){ lane = i; break; } }
    if (lane === -1){ var min = Infinity; for (var j=0;j<this.lanes.length;j++){ if (this.lanes[j] < min){ min = this.lanes[j]; lane = j; } } }
    var el = document.createElement('div');
    el.className = 'cmt';
    el.textContent = text;
    el.style.fontSize = this.fontSize + 'px';
    el.style.opacity = this.opacity;
    if (color) el.style.color = color;
    el.style.top = (lane * this.laneHeight) + 'px';
    this.root.appendChild(el);
    var tw = el.offsetWidth || (text.length * this.fontSize);
    var distance = this.w + tw + 8;
    var duration = distance / this.speed;
    this.lanes[lane] = now + (tw + 24) / this.speed;
    el.style.transition = 'transform ' + duration + 'ms linear';
    void el.offsetHeight;
    el.style.transform = 'translateX(' + (-distance) + 'px)';
    setTimeout(function(){ if (el.parentNode) el.parentNode.removeChild(el); }, duration + 200);
  };
  var danmaku = new Danmaku(danmakuEl);

  // ---- chat: Twitch ----
  function parseTags(raw){ var t={}; raw.split(';').forEach(function(kv){ var i=kv.indexOf('='); if(i>-1) t[kv.slice(0,i)]=kv.slice(i+1); }); return t; }
  function connectTwitch(){
    var ch = CFG.channel.toLowerCase().replace(/^#/, ''), ws;
    function open(){
      ws = new WebSocket('wss://irc-ws.chat.twitch.tv:443');
      ws.onopen = function(){ ws.send('CAP REQ :twitch.tv/tags'); ws.send('PASS SCHMOOPIIE'); ws.send('NICK justinfan'+Math.floor(Math.random()*999999)); ws.send('JOIN #'+ch); };
      ws.onmessage = function(e){
        var lines = e.data.split('\\r\\n');
        for (var i=0;i<lines.length;i++){
          var line = lines[i]; if(!line) continue;
          if (line.indexOf('PING')===0){ ws.send('PONG :tmi.twitch.tv'); continue; }
          var tags={}, rest=line;
          if (line[0]==='@'){ var sp=line.indexOf(' '); tags=parseTags(line.slice(1,sp)); rest=line.slice(sp+1); }
          if (rest.indexOf('PRIVMSG')===-1) continue;
          var mi = rest.indexOf(' :', rest.indexOf('PRIVMSG')); if (mi===-1) continue;
          var text = rest.slice(mi+2);
          var user = tags['display-name'] || (rest.indexOf('!')>-1 ? rest.slice(1, rest.indexOf('!')) : '');
          danmaku.emit(text, tags.color || '', user);
        }
      };
      ws.onclose = function(){ setTimeout(open, 3000); };
      ws.onerror = function(){ try{ ws.close(); }catch(x){} };
    }
    open();
  }

  // ---- chat: Kick ----
  function connectKick(){
    fetch(viaProxy('https://kick.com/api/v2/channels/' + encodeURIComponent(CFG.channel)), { headers:{ 'Accept':'application/json' } })
      .then(function(r){ return r.json(); })
      .then(function(d){ var id = d && d.chatroom && d.chatroom.id; if(!id){ showMsg('Kick: 取得失敗'); return; } subKick(id); })
      .catch(function(){ showMsg('Kick: コメント取得に失敗 (プロキシ設定が必要かも)'); });
  }
  function subKick(id){
    var ws;
    function open(){
      ws = new WebSocket('wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679?protocol=7&client=js&version=8.4.0&flash=false');
      ws.onopen = function(){ ws.send(JSON.stringify({event:'pusher:subscribe', data:{auth:'', channel:'chatrooms.'+id+'.v2'}})); };
      ws.onmessage = function(e){
        var d; try{ d=JSON.parse(e.data); }catch(x){ return; }
        if (d.event === 'App\\\\Events\\\\ChatMessageEvent'){
          var p; try{ p=JSON.parse(d.data); }catch(x){ return; }
          var color = p.sender && p.sender.identity && p.sender.identity.color;
          var user = p.sender && p.sender.username;
          danmaku.emit(p.content, color || '', user || '');
        }
      };
      ws.onclose = function(){ setTimeout(open, 3000); };
      ws.onerror = function(){ try{ ws.close(); }catch(x){} };
    }
    open();
  }

  // ---- chat: TwitCasting ----
  function connectTwitcasting(){
    fetch(viaProxy('https://frontendapi.twitcasting.tv/users/' + encodeURIComponent(CFG.channel) + '/latest-movie'))
      .then(function(r){ return r.json(); })
      .then(function(d){
        var mid = d && d.movie && d.movie.id; if(!mid){ showMsg('ツイキャス: 配信が見つかりません'); return; }
        var body = new URLSearchParams(); body.set('movie_id', mid);
        return fetch(viaProxy('https://twitcasting.tv/eventpubsuburl.php'), { method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body: body.toString() });
      })
      .then(function(r){ return r ? r.json() : null; })
      .then(function(d){ var u = d && d.url; if(!u){ showMsg('ツイキャス: 接続URL取得失敗'); return; } subTwitcasting(u); })
      .catch(function(){ showMsg('ツイキャス: コメント取得に失敗 (プロキシ設定が必要かも)'); });
  }
  function subTwitcasting(wss){
    var ws = new WebSocket(wss);
    ws.onmessage = function(e){
      var arr; try{ arr=JSON.parse(e.data); }catch(x){ return; }
      if(!Array.isArray(arr)) return;
      arr.forEach(function(it){ if (it && it.type==='comment' && it.message) danmaku.emit(it.message, '', (it.author && it.author.name) || ''); });
    };
    ws.onclose = function(){ setTimeout(connectTwitcasting, 5000); };
    ws.onerror = function(){ try{ ws.close(); }catch(x){} };
  }

  // ---- boot ----
  mountPlayer();
  if (CFG.chat){
    if (CFG.platform === 'twitch') connectTwitch();
    else if (CFG.platform === 'kick') connectKick();
    else if (CFG.platform === 'twitcasting') connectTwitcasting();
  }
})();
</script>
</body>
</html>`;
}
