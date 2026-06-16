// iOS NiconicoPlayer.swift の WebSocket 視聴セッションを Android(RN) へ移植。
//
// ニコ生は React Native の直接 fetch/WebSocket を拒否する(anti-bot/TLS、"Network
// request failed")。そこで視聴セッションは「niconico オリジンを読み込んだ隠し WebView」
// の中で実行する: 同一オリジン fetch で watch ページHTMLを取り、data-props から
// WebSocket URL を得て startWatching → stream で HLS uri + cookie を受け取り、
// ReactNativeWebView.postMessage で RN へ橋渡しする。HLS は ExoPlayer(NativeHlsPlayer)
// で再生する(=フルWebページではなく「映像だけ」)。NDGR コメントは viewUri から別途取得。

import type {AppSettings} from './types';

// 隠しセッション WebView を載せる同一オリジンの HTML ページ。
// text/plain(robots.txt 等)では injectedJavaScript が動かないため HTML を使う。
export const niconicoOriginURL = 'https://live.nicovideo.jp/';

export type WatchData = {wsUrl: string; frontendId?: string};

export function niconicoQuality(settings: AppSettings): string {
  // iOS: high -> "abr", economy -> "low"
  return settings.wifiQuality === 'economy' ? 'low' : 'abr';
}

// watch ページHTMLの data-props から WebSocket 情報を取り出す(テスト対象)。
export function parseNiconicoWatchData(html: string): WatchData | null {
  const propsRaw =
    matchGroup(html, /<script[^>]+id=["']embedded-data["'][^>]+data-props=["']([^"']+)["']/) ??
    matchGroup(html, /data-props=["']([^"']+)["'][^>]+id=["']embedded-data["']/) ??
    matchGroup(html, /<script[^>]+id=["']initial-state["'][^>]+data-props=["']([^"']+)["']/) ??
    matchGroup(html, /data-props=["']([^"']+)["'][^>]+id=["']initial-state["']/);
  if (!propsRaw) {
    return null;
  }
  let props: any;
  try {
    props = JSON.parse(decodeHTMLEntities(propsRaw));
  } catch {
    return null;
  }
  const wsEndPoint = props?.pageContents?.watchInformation?.playerParams?.wsEndPoint;
  const newUrl = typeof wsEndPoint?.url === 'string' ? wsEndPoint.url : null;
  if (newUrl) {
    const fid = props?.constants?.requestInfo?.frontendId;
    return {wsUrl: newUrl, frontendId: fid != null ? String(fid) : undefined};
  }
  const site = props?.site;
  const wsString: string | undefined =
    site?.relive?.webSocketUrl ?? site?.webSocketUrl ?? site?.websocketUrl;
  if (typeof wsString === 'string' && wsString) {
    const fid = site?.frontendId ?? site?.frontendID;
    return {wsUrl: wsString, frontendId: fid != null ? String(fid) : undefined};
  }
  return null;
}

// 隠し WebView に注入する視聴セッション JS。niconico オリジン上で動くので
// 同一オリジン fetch / WebSocket が cookie 付き・ブラウザ TLS で通る。
// RN へは {type:'niconicoStream'|'niconicoView'|'niconicoError'|'niconicoEnded'} を postMessage。
export function niconicoSessionScript(programId: string, quality: string): string {
  const lv = JSON.stringify(programId.trim());
  const q = JSON.stringify(quality);
  return `(function(){
  if(window.__mvNico){return;} window.__mvNico=1;
  var lv=${lv}, quality=${q}, tries=0;
  function post(o){ try{ window.ReactNativeWebView.postMessage(JSON.stringify(o)); }catch(e){} }
  function dec(s){ return s.replace(/&quot;/g,'"').replace(/&#34;/g,'"').replace(/&#39;/g,"'").replace(/&apos;/g,"'").replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&#x([0-9a-f]+);/gi,function(_,h){return String.fromCharCode(parseInt(h,16));}).replace(/&#(\\d+);/g,function(_,c){return String.fromCharCode(+c);}).replace(/&amp;/g,'&'); }
  function parseProps(html){
    var m=html.match(/<script[^>]+id="(?:embedded-data|initial-state)"[^>]+data-props="([^"]+)"/)||html.match(/data-props="([^"]+)"[^>]+id="(?:embedded-data|initial-state)"/);
    if(!m) return null;
    try{ return JSON.parse(dec(m[1])); }catch(e){ return null; }
  }
  function wsFrom(p){
    var pp=p&&p.pageContents&&p.pageContents.watchInformation&&p.pageContents.watchInformation.playerParams;
    if(pp&&pp.wsEndPoint&&pp.wsEndPoint.url) return {url:pp.wsEndPoint.url, fid:(p.constants&&p.constants.requestInfo&&p.constants.requestInfo.frontendId)};
    var s=p&&p.site; var u=s&&((s.relive&&s.relive.webSocketUrl)||s.webSocketUrl||s.websocketUrl);
    if(u) return {url:u, fid:(s.frontendId!=null?s.frontendId:s.frontendID)};
    return null;
  }
  function openWS(ws){
    var url=ws.url;
    if(ws.fid!=null && url.indexOf('frontend_id=')<0){ url+=(url.indexOf('?')>=0?'&':'?')+'frontend_id='+encodeURIComponent(ws.fid); }
    var sock; try{ sock=new WebSocket(url); }catch(e){ post({type:'niconicoError',message:String(e&&e.message||e)}); return; }
    var keep=null;
    sock.onopen=function(){ sock.send(JSON.stringify({type:'startWatching',data:{stream:{quality:quality,protocol:'hls',latency:'low',requireNewStream:true,accessRightMethod:'single_cookie',chasePlay:false},room:{protocol:'webSocket',commentable:true},reconnect:false}})); };
    sock.onmessage=function(ev){
      var j; try{ j=JSON.parse(ev.data); }catch(e){ return; }
      if(j.type==='ping'){ sock.send(JSON.stringify({type:'pong'})); return; }
      if(j.type==='seat'){ var iv=(j.data&&j.data.keepIntervalSec)||30; if(keep)clearInterval(keep); sock.send(JSON.stringify({type:'keepSeat'})); keep=setInterval(function(){ try{sock.send(JSON.stringify({type:'keepSeat'}));}catch(e){} }, Math.max(5,iv)*1000); return; }
      if(j.type==='messageServer'){ if(j.data&&j.data.viewUri) post({type:'niconicoView',viewUri:j.data.viewUri}); return; }
      if(j.type==='stream'){ if(j.data&&j.data.uri){ var ck=''; if(Array.isArray(j.data.cookies)){ ck=j.data.cookies.map(function(c){return c.name+'='+c.value;}).join('; '); } post({type:'niconicoStream',hlsUrl:j.data.uri,cookies:ck}); } return; }
      if(j.type==='error'){ post({type:'niconicoError',message:(j.data&&j.data.code)||'error'}); return; }
      if(j.type==='disconnect'){ post({type:'niconicoEnded'}); return; }
    };
    sock.onerror=function(){ post({type:'niconicoError',message:'ws error'}); };
    sock.onclose=function(){ post({type:'niconicoEnded'}); };
  }
  function attempt(){
    fetch('/watch/'+lv,{headers:{'Accept':'text/html'},credentials:'include'}).then(function(r){return r.text();}).then(function(html){
      var ws=wsFrom(parseProps(html));
      if(!ws){ if(++tries<4){ setTimeout(attempt,1500); } else { post({type:'niconicoError',message:'ws url not found'}); } return; }
      openWS(ws);
    }).catch(function(e){ if(++tries<4){ setTimeout(attempt,1500); } else { post({type:'niconicoError',message:String(e&&e.message||e)}); } });
  }
  attempt();
  true;
})();`;
}

function matchGroup(text: string, pattern: RegExp): string | null {
  const match = text.match(pattern);
  return match?.[1] ?? null;
}

function decodeHTMLEntities(value: string): string {
  return value
    .replace(/&quot;/g, '"')
    .replace(/&#34;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) => String.fromCharCode(parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, code) => String.fromCharCode(Number(code)))
    .replace(/&amp;/g, '&');
}
