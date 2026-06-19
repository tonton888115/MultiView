// ツイキャス Android HLS 用の隠し WebView セッションブリッジ。
// twitcasting.tv オリジン上の same-origin fetch で streamserver.php と cookie を取得し、
// NativeHlsPlayer(ExoPlayer) に必要な Cookie ヘッダーを RN 側へ渡す。

export const TWITCASTING_STREAM_PRIORITY = ['medium', 'high', 'low', 'base', 'mobilesource', 'main'] as const;

export function pickTwitcastingHlsUrl(streams: Record<string, any> | null | undefined): string | null {
  if (!streams || typeof streams !== 'object') {
    return null;
  }
  for (const key of TWITCASTING_STREAM_PRIORITY) {
    const value = streams[key];
    if (typeof value === 'string' && value) {
      return value;
    }
  }
  for (const value of Object.values(streams)) {
    if (typeof value === 'string' && value) {
      return value;
    }
  }
  return null;
}

export function twitcastingSessionScript(channel: string): string {
  const target = JSON.stringify(channel.trim());
  const priority = JSON.stringify(TWITCASTING_STREAM_PRIORITY);
  return `(function(){
  if(window.__mvTwitcasting){return;} window.__mvTwitcasting=1;
  var channel=${target}, priority=${priority}, tries=0;
  function post(o){ try{ window.ReactNativeWebView.postMessage(JSON.stringify(o)); }catch(e){} }
  function onOrigin(){ return location.protocol==='https:' && /(^|\\.)twitcasting\\.tv$/.test(location.hostname); }
  function live(v){ return v===true || v===1 || v==='1' || v==='true'; }
  function pick(streams){
    if(!streams || typeof streams!=='object') return null;
    for(var i=0;i<priority.length;i++){ var p=streams[priority[i]]; if(typeof p==='string' && p) return p; }
    for(var k in streams){ if(Object.prototype.hasOwnProperty.call(streams,k)){ var v=streams[k]; if(typeof v==='string' && v) return v; } }
    return null;
  }
  function attempt(){
    if(!onOrigin()){ if(++tries<5){ setTimeout(attempt,800); } else { post({type:'twitcastingError',message:'twitcasting origin not ready'}); } return; }
    var url='https://twitcasting.tv/streamserver.php?target='+encodeURIComponent(channel)+'&mode=client&player=pc_web';
    fetch(url,{credentials:'include',headers:{Accept:'application/json, text/plain, */*','X-Requested-With':'XMLHttpRequest'}}).then(function(r){
      if(!r.ok) throw new Error('HTTP '+r.status);
      return r.json();
    }).then(function(json){
      var isLive=live(json&&json.movie&&json.movie.live);
      var hls=pick(json&&json['tc-hls']&&json['tc-hls'].streams);
      var cookies=''; try{ cookies=document.cookie||''; }catch(e){}
      if(hls){ post({type:'twitcastingStream',hlsUrl:hls,cookies:cookies,isLive:isLive}); return; }
      if(++tries<5){ setTimeout(attempt,1200); return; }
      post({type:'twitcastingOffline',isLive:isLive});
    }).catch(function(e){
      if(++tries<5){ setTimeout(attempt,1200); return; }
      post({type:'twitcastingError',message:String(e&&e.message||e)});
    });
  }
  attempt();
  true;
})();`;
}
