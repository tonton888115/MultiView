// MultiView YouTube extractor (Cloudflare Worker, free tier)
//
// 2026-05 時点で YouTube は signature_cipher を強制し、第三者 API では生 URL を
// 返さなくなった。本 Worker は LuanRT/YouTube.js (youtubei.js) を使い、CF Worker
// 内で base.js を fetch して decipher を完了させ、直接 googlevideo URL を返す。
// VOD は muxed mp4 (360p)、live は HLS manifest URL を返す。
// AVPlayer はいずれもネイティブ再生可能。
//
// Usage:
//   GET /?v=<videoId>
//   GET /health
//
// Response 200:
//   { url, kind: "mp4"|"hls", isLive, title, quality? }
// Response 502:
//   { error, sabrOnly?, info? }
//
// Free tier: 100,000 req/day, no payment required.

import { Innertube, UniversalCache, Platform } from 'youtubei.js/cf-worker';

// Platform.shim.eval は base.js + processor 連結スクリプトを実行する。
// data.output は `return process(...)` で終わるので、IIFE で包んで戻り値を取り出す。
Platform.shim.eval = (data, env) => {
  const keys = Object.keys(env || {});
  const vals = keys.map(k => env[k]);
  const body = `return (function(){ ${data.output} })();`;
  const fn = new Function(...keys, body);
  return fn(...vals);
};

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,OPTIONS',
  'Access-Control-Allow-Headers': '*'
};

function jsonResponse(body, init = {}) {
  return new Response(JSON.stringify(body), {
    ...init,
    headers: { ...CORS, 'Content-Type': 'application/json; charset=utf-8', ...(init.headers || {}) }
  });
}

let ytPromise = null;
function getYT() {
  if (!ytPromise) {
    ytPromise = Innertube.create({
      cache: new UniversalCache(false),
      generate_session_locally: true,
      retrieve_player: true
    });
  }
  return ytPromise;
}

async function extractURL(videoId) {
  const yt = await getYT();
  const info = await yt.getInfo(videoId);
  const isLive = !!info.basic_info?.is_live;
  const title = info.basic_info?.title || '';
  const sd = info.streaming_data;
  if (!sd) {
    return { error: 'no streaming_data', title };
  }

  // Live: HLS manifest が最優先 (AVPlayer がネイティブ再生)
  if (isLive && sd.hls_manifest_url) {
    return { url: sd.hls_manifest_url, kind: 'hls', isLive: true, title };
  }
  // VOD: muxed mp4 (audio+video 同梱の 360p itag=18) を decipher
  const muxed = (sd.formats || []).filter(f => f.has_audio && f.has_video);
  if (muxed.length) {
    const best = muxed.sort((a, b) => (b.height || 0) - (a.height || 0))[0];
    try {
      const ciphered = await best.decipher(yt.session.player);
      const url = typeof ciphered === 'string' ? ciphered : (ciphered && (ciphered.url || ciphered.toString())) || null;
      if (url) {
        return { url, kind: 'mp4', isLive: false, title, quality: best.quality_label };
      }
    } catch (e) {
      return { error: 'decipher failed: ' + (e.message || e), title };
    }
  }
  // どこにも muxed が無い場合は SABR only。AVPlayer で直接再生できない。
  return { error: 'no playable format (SABR only)', sabrOnly: !!sd.server_abr_streaming_url, title };
}

export default {
  async fetch(request) {
    if (request.method === 'OPTIONS') return new Response(null, { headers: CORS });
    const url = new URL(request.url);
    if (url.pathname === '/health') {
      return jsonResponse({ ok: true, version: '2026-05-27', engine: 'youtubei.js' });
    }
    const videoId = url.searchParams.get('v');
    if (!videoId || !/^[A-Za-z0-9_-]{6,32}$/.test(videoId)) {
      return jsonResponse({ error: 'missing or invalid ?v=' }, { status: 400 });
    }
    try {
      const result = await extractURL(videoId);
      if (result.error) {
        return jsonResponse(result, { status: 502 });
      }
      return jsonResponse(result);
    } catch (e) {
      return jsonResponse({ error: 'extractor exception: ' + (e.message || e) }, { status: 500 });
    }
  }
};
