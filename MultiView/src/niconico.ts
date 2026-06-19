// iOS NiconicoPlayer.swift の WebSocket 視聴セッションを Android(RN) へ移植。
//
// ニコ生は React Native の直接 fetch/WebSocket を拒否する(anti-bot/TLS、"Network
// request failed")。そこで視聴セッションは「niconico オリジンを読み込んだ隠し WebView」
// の中で実行する: 同一オリジン fetch で watch ページHTMLを取り、data-props から
// WebSocket URL を得て startWatching → stream で HLS uri + cookie を受け取り、
// ReactNativeWebView.postMessage で RN へ橋渡しする。HLS は ExoPlayer(NativeHlsPlayer)
// で再生する(=フルWebページではなく「映像だけ」)。NDGR コメントは viewUri から別途取得。

import type {PlaybackQuality} from './types';

// 隠しセッション WebView を載せる同一オリジンの HTML ページ。
// text/plain(robots.txt 等)では injectedJavaScript が動かないため HTML を使う。
export const niconicoOriginURL = 'https://live.nicovideo.jp/';

export type WatchData = {wsUrl: string; frontendId?: string};

export function niconicoQuality(quality: PlaybackQuality): string {
  // iOS: high -> "abr", economy -> "low"
  return quality === 'economy' ? 'low' : 'abr';
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
  var td=(typeof TextDecoder!=='undefined')?new TextDecoder('utf-8'):null;
  function decU(b){ try{ return td?td.decode(b):decodeURIComponent(escape(String.fromCharCode.apply(null,b))); }catch(e){ return ''; } }
  function pbFields(bytes){ var out=[],p=0; function vi(){ var r=0,s=1,b; while(p<bytes.length){ b=bytes[p++]; r+=(b&0x7f)*s; if((b&0x80)===0) return r; s*=128; } return null; } while(p<bytes.length){ var k=vi(); if(k===null) break; var num=Math.floor(k/8), wt=k&7; if(wt===0){ var v=vi(); if(v===null) break; out.push({n:num,v:v}); } else if(wt===2){ var len=vi(); if(len===null||p+len>bytes.length) break; out.push({n:num,d:bytes.subarray(p,p+len)}); p+=len; } else if(wt===1){ p+=8; } else if(wt===5){ p+=4; } else break; } return out; }
  function sub(fs,n){ for(var i=0;i<fs.length;i++){ if(fs[i].n===n&&fs[i].d) return fs[i].d; } return null; }
  function str(fs,n){ var d=sub(fs,n); return d?decU(d):''; }
  function adText(ad){ var f=pbFields(ad); var v2=sub(f,2); if(v2){ var m=str(pbFields(v2),2); return m||'ニコニ広告されました'; } var v0=sub(f,1); if(v0){ var lf=sub(pbFields(v0),1); if(lf){ var lff=pbFields(lf); var m2=str(lff,3); if(m2) return m2; var adv=str(lff,1); if(adv) return adv+' がニコニ広告しました'; } } return 'ニコニ広告されました'; }
  function readProto(url,onMsg,onEnd){ fetch(url).then(function(r){ if(!r.body){ if(onEnd)onEnd(); return; } var rd=r.body.getReader(); var buf=new Uint8Array(0); function pump(){ rd.read().then(function(res){ if(res.done){ if(onEnd)onEnd(); return; } var nb=new Uint8Array(buf.length+res.value.length); nb.set(buf); nb.set(res.value,buf.length); buf=nb; var p=0; while(true){ var q=p,r2=0,s=1,bb,got=false; while(q<buf.length){ bb=buf[q++]; r2+=(bb&0x7f)*s; if((bb&0x80)===0){got=true;break;} s*=128; } if(!got) break; if(q+r2>buf.length) break; onMsg(buf.subarray(q,q+r2)); p=q+r2; } if(p>0) buf=buf.subarray(p); pump(); }).catch(function(){ if(onEnd)onEnd(); }); } pump(); }).catch(function(){ if(onEnd)onEnd(); }); }
  var nicoAt='now', nicoActive={};
  function ndgr(viewUri){ if(window.__mvNdgr) return; window.__mvNdgr=1; nicoView(viewUri); }
  function nicoView(viewUri){ var url=viewUri+(viewUri.indexOf('?')>=0?'&':'?')+'at='+encodeURIComponent(nicoAt); var any=false; readProto(url,function(msg){ any=true; var fs=pbFields(msg); var seg=sub(fs,1); if(seg){ var u=sub(pbFields(seg),3); if(u){ var su=decU(u); if(!nicoActive[su]){ nicoActive[su]=1; nicoSeg(su); } } } var nx=sub(fs,4); if(nx){ var nf=pbFields(nx); for(var i=0;i<nf.length;i++){ if(nf[i].n===1&&nf[i].v!=null) nicoAt=String(nf[i].v); } } },function(){ setTimeout(function(){ nicoView(viewUri); }, any?500:2500); }); }
  function nicoSeg(uri){ readProto(uri,function(msg){ var fs=pbFields(msg); var m=sub(fs,2); if(!m) return; var mf=pbFields(m);
    var chat=sub(mf,1)||sub(mf,20); if(chat){ var t=str(pbFields(chat),1); if(t) post({type:'niconicoComment',text:t}); }
    var gift=sub(mf,8); if(gift){ var gf=pbFields(gift); var sender=str(gf,3)||'誰か'; var item=str(gf,6)||str(gf,1)||'ギフト'; post({type:'niconicoEvent',kind:'gift',text:'🎁 '+sender+' が '+item+' を贈りました'}); }
    var ad=sub(mf,9); if(ad){ post({type:'niconicoEvent',kind:'nicoad',text:'📢 '+adText(ad)}); }
    var noti=sub(mf,23); if(noti){ var nm=str(pbFields(noti),2); if(nm) post({type:'niconicoEvent',kind:'notification',text:'🔔 '+nm}); }
  },function(){ delete nicoActive[uri]; }); }
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
      if(j.type==='messageServer'){ if(j.data&&j.data.viewUri){ post({type:'niconicoView',viewUri:j.data.viewUri}); ndgr(j.data.viewUri); } return; }
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
