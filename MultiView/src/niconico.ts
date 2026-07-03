// iOS NiconicoPlayer.swift の WebSocket 視聴セッションを Android(RN) へ移植。
//
// ニコ生は React Native の直接 fetch/WebSocket を拒否する(anti-bot/TLS、"Network
// request failed")。そこで視聴セッションは「niconico オリジンを読み込んだ隠し WebView」
// の中で実行する: 同一オリジン fetch で watch ページHTMLを取り、data-props から
// WebSocket URL を得て startWatching → stream で HLS uri + cookie を受け取り、
// ReactNativeWebView.postMessage で RN へ橋渡しする。HLS は ExoPlayer(NativeHlsPlayer)
// で再生する(=フルWebページではなく「映像だけ」)。NDGR コメントは viewUri から別途取得。

import type {AppSettings, PlaybackQuality} from './types';

export type NiconicoSupportKind = 'gift' | 'nicoad' | 'notification';
export type NiconicoSupportPresentation = 'hidden' | 'overlay';

const niconicoSupportMarkers = [
  'ギフト',
  'ニコニ広告',
  '広告しました',
  '貢献',
  'サポーター',
  'レベルアップ',
  'gift',
  'nicoad',
  'support',
  'koken',
];

// iOS NiconicoPlayer.emitSupportEvent parity: support events use only the
// dedicated overlay. They are never ordinary comments/danmaku.
export function niconicoSupportPresentation(
  kind: NiconicoSupportKind,
  settings: Pick<AppSettings, 'showGiftEffects' | 'niconicoShowGift' | 'niconicoShowNicoad' | 'niconicoShowNotification'>,
): NiconicoSupportPresentation {
  if (kind === 'gift') {
    return settings.showGiftEffects && settings.niconicoShowGift ? 'overlay' : 'hidden';
  }
  if (kind === 'nicoad') {
    return settings.niconicoShowNicoad ? 'overlay' : 'hidden';
  }
  return settings.niconicoShowNotification ? 'overlay' : 'hidden';
}

// iOS only treats supporter/level-up or support-marker messages as support
// notifications. Generic visitor/entrance notices must not become comments.
export function isNiconicoSupportNotification(type: number | undefined, message: string): boolean {
  if (type === 7 || type === 8) {
    return true;
  }
  const lower = message.toLowerCase();
  return niconicoSupportMarkers.some(marker => lower.includes(marker.toLowerCase()));
}

// 隠しセッション WebView を載せる同一オリジンの HTML ページ。
// text/plain(robots.txt 等)では injectedJavaScript が動かないため HTML を使う。
export const niconicoOriginURL = 'https://live.nicovideo.jp/';

function injectedJSONString(value: string): string {
  return JSON.stringify(value)
    .replace(/\u2028/g, '\\u2028')
    .replace(/\u2029/g, '\\u2029');
}

// Run inside the hidden niconico-origin WebView. The session script owns the
// watch WebSocket; RN only hands it a request id and text, then waits for the
// correlated niconicoCommentPostResult message before showing success.
export function niconicoPostCommentScript(requestId: string, text: string): string {
  const id = injectedJSONString(requestId);
  const content = injectedJSONString(text);
  return `(function(){
  var requestId=${id};
  try{
    if(typeof window.__mvNicoPostComment!=='function') throw new Error('ニコ生のコメント接続がまだ準備できていません。再読み込み後にもう一度試してください。');
    window.__mvNicoPostComment(requestId,${content});
  }catch(e){
    try{window.ReactNativeWebView.postMessage(JSON.stringify({type:'niconicoCommentPostResult',requestId:requestId,ok:false,message:String(e&&e.message||e)}));}catch(_){}
  }
})();true;`;
}

export type NiconicoNativeBlockReason = {
  reason: 'ticket' | 'payment' | 'login' | 'country';
  message: string;
};

export type WatchData = {
  wsUrl: string;
  frontendId?: string;
  nativeBlockReason?: NiconicoNativeBlockReason;
};

export function niconicoQuality(quality: PlaybackQuality): string {
  // iOS: high -> "abr", economy -> "low"
  return quality === 'economy' ? 'low' : 'abr';
}

// watch ページHTMLの data-props から WebSocket 情報を取り出す(テスト対象)。
export function parseNiconicoWatchData(html: string): WatchData | null {
  const propsRaw = extractNiconicoProps(html);
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
    return watchData(newUrl, fid != null ? String(fid) : undefined, props);
  }
  const site = props?.site;
  const wsString: string | undefined =
    site?.relive?.webSocketUrl ?? site?.webSocketUrl ?? site?.websocketUrl;
  if (typeof wsString === 'string' && wsString) {
    const fid = site?.frontendId ?? site?.frontendID;
    return watchData(wsString, fid != null ? String(fid) : undefined, props);
  }
  return null;
}

function watchData(wsUrl: string, frontendId: string | undefined, props: any): WatchData {
  const parsed: WatchData = frontendId ? {wsUrl, frontendId} : {wsUrl};
  const nativeBlockReason = niconicoNativeBlockReason(props);
  if (nativeBlockReason) {
    parsed.nativeBlockReason = nativeBlockReason;
  }
  return parsed;
}

export function niconicoNativeBlockReason(props: any): NiconicoNativeBlockReason | null {
  const user = props?.user;
  const userWatch = props?.userProgramWatch;
  const condition = props?.programWatch?.condition;
  const loginStatus = user?.login_status ?? user?.loginStatus;
  const isLoggedOut =
    user?.isLoggedIn === false ||
    loginStatus === 'not_login' ||
    (loginStatus == null && user?.member_status === null);
  if (userWatch?.isCountryRestrictionTarget === true) {
    return {reason: 'country', message: 'この地域からは視聴できません'};
  }
  if (condition?.needLogin === true && isLoggedOut) {
    return {reason: 'login', message: 'ログインが必要です'};
  }
  const payment = typeof condition?.payment === 'string' ? condition.payment : '';
  const hasTicket = userWatch?.payment?.hasTicket;
  if (payment && !['None', 'Free', 'NoPayment'].includes(payment) && hasTicket === false) {
    return {
      reason: payment === 'Ticket' ? 'ticket' : 'payment',
      message: payment === 'Ticket' ? 'チケット購入者限定です' : '有料または会員限定番組です',
    };
  }
  if (isLoggedOut && userWatch?.canWatch === false) {
    return {reason: 'login', message: 'ログインが必要です'};
  }
  return null;
}

// iOS NiconicoPlayer.isEndedWatchPage と同じく、ページ全体の文言ではなく
// 番組情報JSON内の明示的な終了シグナルだけを見る。フッターや推薦枠の文言で誤判定しないため。
export function isNiconicoEndedWatchPage(html: string): boolean {
  if (/data-program-status=["']ENDED["']/.test(html)) {
    return true;
  }
  const propsRaw = extractNiconicoProps(html);
  if (!propsRaw) {
    return false;
  }
  let props: any;
  try {
    props = JSON.parse(decodeHTMLEntities(propsRaw));
  } catch {
    return false;
  }
  const statuses = [
    props?.program?.status,
    props?.program?.state,
    props?.program?.programStatus,
    props?.site?.relive?.status,
    props?.site?.relive?.programStatus,
    props?.pageContents?.watchInformation?.program?.status,
  ];
  return statuses.some(value => typeof value === 'string' && value.toUpperCase() === 'ENDED');
}

// 隠し WebView に注入する視聴セッション JS。niconico オリジン上で動くので
// 同一オリジン fetch / WebSocket が cookie 付き・ブラウザ TLS で通る。
// RN へは {type:'niconicoStream'|'niconicoView'|'niconicoError'|'niconicoEnded'} を postMessage。
export function niconicoSessionScript(programId: string, quality: string): string {
  const lv = JSON.stringify(programId.trim());
  const q = JSON.stringify(quality);
  const supportMarkers = JSON.stringify(niconicoSupportMarkers);
  return `(function(){
  if(window.__mvNico){return;} window.__mvNico=1;
  var lv=${lv}, quality=${q}, tries=0, streamSeen=false, streamOpenedAt=0, commentLoginState='unknown';
  var reconnectTimer=null, socketGeneration=0, activeSocket=null, activeKeep=null, loadGeneration=0, loadRetryTimer=null;
  function post(o){ try{ window.ReactNativeWebView.postMessage(JSON.stringify(o)); }catch(e){} }
  function commentResult(requestId,ok,message){ post({type:'niconicoCommentPostResult',requestId:requestId,ok:ok,message:message||undefined}); }
  window.__mvNicoPostComment=function(requestId,text){
    try{
      if(typeof requestId!=='string'||!requestId) return;
      var content=typeof text==='string'?text.trim():'';
      if(!content){ commentResult(requestId,false,'コメントを入力してください'); return; }
      if(commentLoginState==='out'){ commentResult(requestId,false,'ニコ生にログインしてください'); return; }
      var sock=activeSocket;
      if(!sock||sock.readyState!==1){ commentResult(requestId,false,'ニコ生のコメント接続がまだ準備できていません。再読み込み後にもう一度試してください。'); return; }
      var vpos=streamOpenedAt?Math.max(0,Math.floor((Date.now()-streamOpenedAt)/10)):0;
      sock.send(JSON.stringify({type:'postComment',data:{text:content,vpos:vpos}}));
      commentResult(requestId,true);
    }catch(e){ commentResult(requestId,false,String(e&&e.message||e)); }
  };
  function dec(s){ return s.replace(/&quot;/g,'"').replace(/&#34;/g,'"').replace(/&#39;/g,"'").replace(/&apos;/g,"'").replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&#x([0-9a-f]+);/gi,function(_,h){return String.fromCharCode(parseInt(h,16));}).replace(/&#(\\d+);/g,function(_,c){return String.fromCharCode(+c);}).replace(/&amp;/g,'&'); }
  function endedProps(p){ var values=[p&&p.program&&p.program.status,p&&p.program&&p.program.state,p&&p.program&&p.program.programStatus,p&&p.site&&p.site.relive&&p.site.relive.status,p&&p.site&&p.site.relive&&p.site.relive.programStatus,p&&p.pageContents&&p.pageContents.watchInformation&&p.pageContents.watchInformation.program&&p.pageContents.watchInformation.program.status]; return values.some(function(v){return typeof v==='string'&&v.toUpperCase()==='ENDED';}); }
  function endedPayload(p){ var vals=[p&&p.code,p&&p.reason,p&&p.type].filter(function(v){return typeof v==='string';}).map(function(v){return v.toUpperCase();}); var codes={END_PROGRAM:1,PROGRAM_END:1,PROGRAM_ENDED:1,ENDED:1,BROADCAST_ENDED:1,FINISHED:1,END_ENTERTAINMENT:1}; for(var i=0;i<vals.length;i++){ if(codes[vals[i]]) return true; } return !!(p&&(p.programEnded===true||p.ended===true)); }
  function parseProps(html){
    var m=html.match(/<script[^>]+id="(?:embedded-data|initial-state)"[^>]+data-props="([^"]+)"/)||html.match(/data-props="([^"]+)"[^>]+id="(?:embedded-data|initial-state)"/);
    if(!m) return null;
    try{ return JSON.parse(dec(m[1])); }catch(e){ return null; }
  }
  function wsFrom(p){
    var blocked=nativeBlockReason(p);
    var pp=p&&p.pageContents&&p.pageContents.watchInformation&&p.pageContents.watchInformation.playerParams;
    if(pp&&pp.wsEndPoint&&pp.wsEndPoint.url) return {url:pp.wsEndPoint.url, fid:(p.constants&&p.constants.requestInfo&&p.constants.requestInfo.frontendId), blocked:blocked};
    var s=p&&p.site; var u=s&&((s.relive&&s.relive.webSocketUrl)||s.webSocketUrl||s.websocketUrl);
    if(u) return {url:u, fid:(s.frontendId!=null?s.frontendId:s.frontendID), blocked:blocked};
    return null;
  }
  function nativeBlockReason(p){
    var user=p&&p.user, userWatch=p&&p.userProgramWatch, condition=p&&p.programWatch&&p.programWatch.condition;
    var loginStatus=user&&(user.login_status!=null?user.login_status:user.loginStatus);
    var isLoggedOut=!!(user&&(user.isLoggedIn===false||loginStatus==='not_login'||(loginStatus==null&&user.member_status===null)));
    if(userWatch&&userWatch.isCountryRestrictionTarget===true) return {reason:'country',message:'この地域からは視聴できません'};
    if(condition&&condition.needLogin===true&&isLoggedOut) return {reason:'login',message:'ログインが必要です'};
    var payment=condition&&typeof condition.payment==='string'?condition.payment:'';
    var hasTicket=userWatch&&userWatch.payment&&userWatch.payment.hasTicket;
    if(payment&&['None','Free','NoPayment'].indexOf(payment)<0&&hasTicket===false){
      return {reason:(payment==='Ticket'?'ticket':'payment'),message:(payment==='Ticket'?'チケット購入者限定です':'有料または会員限定番組です')};
    }
    if(isLoggedOut&&userWatch&&userWatch.canWatch===false) return {reason:'login',message:'ログインが必要です'};
    return null;
  }
  function updateCommentLoginState(p){
    var user=p&&p.user;
    if(!user)return;
    var status=user.login_status!=null?user.login_status:user.loginStatus;
    if(user.isLoggedIn===false||status==='not_login'||(status==null&&user.member_status===null)) commentLoginState='out';
    else if(user.isLoggedIn===true||status==='login'||user.member_status!=null) commentLoginState='in';
  }
  var td=(typeof TextDecoder!=='undefined')?new TextDecoder('utf-8'):null;
  function decU(b){ try{ return td?td.decode(b):decodeURIComponent(escape(String.fromCharCode.apply(null,b))); }catch(e){ return ''; } }
  function pbFields(bytes){ var out=[],p=0; function vi(){ var r=0,s=1,b; while(p<bytes.length){ b=bytes[p++]; r+=(b&0x7f)*s; if((b&0x80)===0) return r; s*=128; } return null; } while(p<bytes.length){ var k=vi(); if(k===null) break; var num=Math.floor(k/8), wt=k&7; if(wt===0){ var v=vi(); if(v===null) break; out.push({n:num,v:v}); } else if(wt===2){ var len=vi(); if(len===null||p+len>bytes.length) break; out.push({n:num,d:bytes.subarray(p,p+len)}); p+=len; } else if(wt===1){ p+=8; } else if(wt===5){ p+=4; } else break; } return out; }
  function sub(fs,n){ for(var i=0;i<fs.length;i++){ if(fs[i].n===n&&fs[i].d) return fs[i].d; } return null; }
  function str(fs,n){ var d=sub(fs,n); return d?decU(d):''; }
  function intv(fs,n){ for(var i=0;i<fs.length;i++){ if(fs[i].n===n&&fs[i].v!=null) return fs[i].v; } return null; }
  var supportMarkers=${supportMarkers};
  function supportNotification(noti){ var nf=pbFields(noti), type=intv(nf,1), message=str(nf,2); if(!message)return ''; if(type===7||type===8)return message; var lower=message.toLowerCase(); for(var i=0;i<supportMarkers.length;i++){if(lower.indexOf(supportMarkers[i].toLowerCase())>=0)return message;} return ''; }
  function adText(ad){ var f=pbFields(ad); var v2=sub(f,2); if(v2){ var m=str(pbFields(v2),2); return m||'ニコニ広告されました'; } var v0=sub(f,1); if(v0){ var lf=sub(pbFields(v0),1); if(lf){ var lff=pbFields(lf); var m2=str(lff,3); if(m2) return m2; var adv=str(lff,1); if(adv) return adv+' がニコニ広告しました'; } } return 'ニコニ広告されました'; }
  function makeController(){ return typeof AbortController!=='undefined'?new AbortController():null; }
  function readProto(url,onMsg,onEnd,idleMs,controller){
    var finished=false, reader=null, idleTimer=null, received=false;
    function finish(reason){ if(finished)return; finished=true; if(idleTimer)clearTimeout(idleTimer); idleTimer=null; if(onEnd)onEnd(received,reason); }
    function armIdle(){ if(idleTimer)clearTimeout(idleTimer); if(idleMs>0){ idleTimer=setTimeout(function(){ try{if(controller)controller.abort();else if(reader)reader.cancel();}catch(e){} finish('idle'); },idleMs); } }
    var options=controller?{signal:controller.signal}:{};
    fetch(url,options).then(function(r){ if(!r.ok)throw new Error('HTTP '+r.status); if(!r.body)throw new Error('no body'); reader=r.body.getReader(); var buf=new Uint8Array(0); armIdle(); function pump(){ reader.read().then(function(res){ if(finished)return; if(res.done){finish('closed');return;} received=true; armIdle(); var nb=new Uint8Array(buf.length+res.value.length); nb.set(buf); nb.set(res.value,buf.length); buf=nb; var p=0; while(true){ var q=p,r2=0,s=1,bb,got=false; while(q<buf.length){ bb=buf[q++]; r2+=(bb&0x7f)*s; if((bb&0x80)===0){got=true;break;} s*=128; } if(!got||q+r2>buf.length)break; onMsg(buf.subarray(q,q+r2)); p=q+r2; } if(p>0)buf=buf.subarray(p); pump(); }).catch(function(e){finish(e&&e.name==='AbortError'?'aborted':'read');}); } pump(); }).catch(function(e){finish(e&&e.name==='AbortError'?'aborted':'fetch');});
  }
  var nicoAt='now', nicoActive={}, nicoViewUri=null, nicoViewGeneration=0, nicoViewController=null, nicoViewRetry=null, nicoFailures=0, nicoLastSuccess=Date.now(), nicoReconnectStarted=0, nicoEscalated=false;
  function stopNdgr(){ nicoViewGeneration++; if(nicoViewRetry)clearTimeout(nicoViewRetry); nicoViewRetry=null; try{if(nicoViewController)nicoViewController.abort();}catch(e){} nicoViewController=null; Object.keys(nicoActive).forEach(function(uri){var entry=nicoActive[uri]; if(entry&&entry.timer)clearTimeout(entry.timer); try{if(entry&&entry.controller)entry.controller.abort();}catch(e){} }); nicoActive={}; }
  function reportCommentFailure(message){ if(nicoEscalated)return; nicoEscalated=true; post({type:'niconicoCommentBridgeError',message:message||'comment session stalled'}); stopNdgr(); reconnectSession(1000); }
  function ndgr(viewUri){ if(!viewUri||viewUri===nicoViewUri&&nicoViewController)return; stopNdgr(); nicoViewUri=viewUri; nicoAt='now'; nicoFailures=0; nicoLastSuccess=Date.now(); nicoReconnectStarted=0; nicoEscalated=false; nicoView(viewUri,nicoViewGeneration); }
  function nicoView(viewUri,generation){ if(generation!==nicoViewGeneration)return; var url=viewUri+(viewUri.indexOf('?')>=0?'&':'?')+'at='+encodeURIComponent(nicoAt); var any=false; var controller=makeController(); nicoViewController=controller; readProto(url,function(msg){ if(generation!==nicoViewGeneration)return; any=true; nicoFailures=0; nicoReconnectStarted=0; nicoLastSuccess=Date.now(); var fs=pbFields(msg); var seg=sub(fs,1); if(seg){ var u=sub(pbFields(seg),3); if(u){ var su=decU(u); if(su&&!nicoActive[su])nicoSeg(su,generation,1); } } var nx=sub(fs,4); if(nx){ var nf=pbFields(nx); for(var i=0;i<nf.length;i++){ if(nf[i].n===1&&nf[i].v!=null)nicoAt=String(nf[i].v); } } },function(received,reason){ if(generation!==nicoViewGeneration)return; nicoViewController=null; if(!received){ nicoFailures++; if(!nicoReconnectStarted)nicoReconnectStarted=Date.now(); } var sinceSuccess=Date.now()-nicoLastSuccess, sinceReconnect=nicoReconnectStarted?Date.now()-nicoReconnectStarted:0; if(nicoFailures>=3||sinceSuccess>20000||sinceReconnect>12000){reportCommentFailure('comment view stalled: '+reason);return;} var delay=any?500:Math.min(Math.pow(2,Math.max(0,nicoFailures-1))*1000,4000); nicoViewRetry=setTimeout(function(){nicoViewRetry=null;nicoView(viewUri,generation);},delay); },12000,controller); }
  function nicoSeg(uri,generation,attempt){ if(generation!==nicoViewGeneration)return; var controller=makeController(), entry={controller:controller,timer:null}; nicoActive[uri]=entry; var seq=0, delivered=false; readProto(uri,function(msg){ if(generation!==nicoViewGeneration)return; delivered=true; nicoLastSuccess=Date.now(); seq++; var fs=pbFields(msg); var meta=sub(fs,1); var metaFields=meta?pbFields(meta):[]; var eventId=str(metaFields,1)||str(metaFields,2)||str(metaFields,3)||('segment:'+uri+':'+seq); var m=sub(fs,2); if(!m)return; var mf=pbFields(m);
    var chat=sub(mf,1)||sub(mf,20); if(chat){ var t=str(pbFields(chat),1); if(t) post({type:'niconicoComment',id:eventId,text:t}); }
    var gift=sub(mf,8); if(gift){ var gf=pbFields(gift); var sender=str(gf,3)||'誰か'; var item=str(gf,6)||str(gf,1)||'ギフト'; post({type:'niconicoEvent',id:eventId,kind:'gift',text:'🎁 '+sender+' が '+item+' を贈りました'}); }
    var ad=sub(mf,9); if(ad){ post({type:'niconicoEvent',id:eventId,kind:'nicoad',text:'📢 '+adText(ad)}); }
    var noti=sub(mf,23); if(noti){ var nm=supportNotification(noti); if(nm) post({type:'niconicoEvent',id:eventId,kind:'notification',text:'🔔 '+nm}); }
  },function(_received,reason){ if(generation!==nicoViewGeneration)return; delete nicoActive[uri]; if(delivered)return; if(attempt<4){ var timer=setTimeout(function(){nicoSeg(uri,generation,attempt+1);},Math.min(Math.pow(2,attempt-1)*1000,4000)); nicoActive[uri]={controller:null,timer:timer}; }else{ reportCommentFailure('comment segment failed: '+reason); } },60000,controller); }
  function closeActiveSocket(){ if(activeKeep)clearInterval(activeKeep); activeKeep=null; var sock=activeSocket; activeSocket=null; if(!sock)return; sock.onopen=null; sock.onmessage=null; sock.onerror=null; sock.onclose=null; try{sock.close();}catch(e){} }
  function reconnectSession(delay){ if(reconnectTimer)return; closeActiveSocket(); loadGeneration++; if(loadRetryTimer)clearTimeout(loadRetryTimer); loadRetryTimer=null; reconnectTimer=setTimeout(function(){ reconnectTimer=null; tries=0; attempt(); },delay||3000); }
  function retryAfterLoadFailure(message){ post({type:'niconicoError',message:message}); reconnectSession(10000); }
  function openWS(ws){
    closeActiveSocket();
    var url=ws.url;
    if(ws.fid!=null && url.indexOf('frontend_id=')<0){ url+=(url.indexOf('?')>=0?'&':'?')+'frontend_id='+encodeURIComponent(ws.fid); }
    var sock; try{ sock=new WebSocket(url); }catch(e){ retryAfterLoadFailure(String(e&&e.message||e)); return; }
    var generation=++socketGeneration; activeSocket=sock;
    function current(){return activeSocket===sock&&generation===socketGeneration;}
    function recoverSocket(message){ if(!current())return; if(!streamSeen)post({type:'niconicoError',message:message}); reconnectSession(3000); }
    sock.onopen=function(){ if(!current())return; sock.send(JSON.stringify({type:'startWatching',data:{stream:{quality:quality,protocol:'hls',latency:'low',requireNewStream:true,accessRightMethod:'single_cookie',chasePlay:false},room:{protocol:'webSocket',commentable:true},reconnect:false}})); };
    sock.onmessage=function(ev){
      if(!current())return;
      var j; try{ j=JSON.parse(ev.data); }catch(e){ return; }
      if(j.type==='ping'){ sock.send(JSON.stringify({type:'pong'})); return; }
      if(j.type==='seat'){ var iv=(j.data&&j.data.keepIntervalSec)||30; if(activeKeep)clearInterval(activeKeep); sock.send(JSON.stringify({type:'keepSeat'})); activeKeep=setInterval(function(){ if(!current())return; try{sock.send(JSON.stringify({type:'keepSeat'}));}catch(e){} },Math.max(5,iv)*1000); return; }
      if(j.type==='messageServer'){ if(j.data&&j.data.viewUri){ post({type:'niconicoView',viewUri:j.data.viewUri}); ndgr(j.data.viewUri); } return; }
      if(j.type==='stream'){ if(j.data&&j.data.uri){ streamSeen=true; if(!streamOpenedAt)streamOpenedAt=Date.now(); var ck=''; if(Array.isArray(j.data.cookies)){ ck=j.data.cookies.map(function(c){return c.name+'='+c.value;}).join('; '); } post({type:'niconicoStream',hlsUrl:j.data.uri,cookies:ck}); } return; }
      if(j.type==='error'){ if(endedPayload(j.data)){ stopNdgr(); closeActiveSocket(); post({type:'niconicoEnded',message:'番組が終了しました'}); return; } recoverSocket((j.data&&j.data.code)||'error'); return; }
      if(j.type==='disconnect'){ if(endedPayload(j.data)){ stopNdgr(); closeActiveSocket(); post({type:'niconicoEnded',message:'番組が終了しました'}); return; } recoverSocket('disconnect'); return; }
    };
    sock.onerror=function(){ recoverSocket('ws error'); };
    sock.onclose=function(){ recoverSocket('ws closed'); };
  }
  function attempt(){
    var generation=++loadGeneration;
    fetch('/watch/'+lv,{headers:{'Accept':'text/html'},credentials:'include'}).then(function(r){if(!r.ok)throw new Error('HTTP '+r.status);return r.text();}).then(function(html){
      if(generation!==loadGeneration)return; var props=parseProps(html); updateCommentLoginState(props);
      if(endedProps(props)||/data-program-status=["']ENDED["']/.test(html)){ stopNdgr(); closeActiveSocket(); post({type:'niconicoEnded',message:'番組が終了しました'}); return; }
      var ws=wsFrom(props);
      if(!ws){ if(++tries<4){ loadRetryTimer=setTimeout(function(){loadRetryTimer=null;attempt();},1500); } else { retryAfterLoadFailure('ws url not found'); } return; }
      if(ws.blocked){ post({type:'niconicoNativeBlocked',reason:ws.blocked.reason,message:ws.blocked.message}); return; }
      openWS(ws);
    }).catch(function(e){ if(generation!==loadGeneration)return; if(++tries<4){ loadRetryTimer=setTimeout(function(){loadRetryTimer=null;attempt();},1500); } else { retryAfterLoadFailure(String(e&&e.message||e)); } });
  }
  attempt();
  true;
})();`;
}

function matchGroup(text: string, pattern: RegExp): string | null {
  const match = text.match(pattern);
  return match?.[1] ?? null;
}

function extractNiconicoProps(html: string): string | null {
  return (
    matchGroup(html, /<script[^>]+id=["']embedded-data["'][^>]+data-props=["']([^"']+)["']/) ??
    matchGroup(html, /data-props=["']([^"']+)["'][^>]+id=["']embedded-data["']/) ??
    matchGroup(html, /<script[^>]+id=["']initial-state["'][^>]+data-props=["']([^"']+)["']/) ??
    matchGroup(html, /data-props=["']([^"']+)["'][^>]+id=["']initial-state["']/)
  );
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
