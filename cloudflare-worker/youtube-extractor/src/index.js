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

import { Innertube, Platform } from 'youtubei.js/cf-worker';

// CF Worker free 枠は `new Function` を禁止しており、unsafe_eval binding も
// 別途申請制で使えない。VOD の signature_cipher 解読は不可能。
// しかしライブ配信 (HLS manifest URL) は cipher 不要なので問題なく動く。
// shim.eval は呼ばれた時だけ「VOD は CF Worker では非対応」と明示エラーする。
Platform.shim.eval = () => {
  throw new Error('VOD_DECIPHER_UNAVAILABLE_ON_CF_FREE');
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

// youtubei.js の cf-worker Cache は cache.match に plain string を渡してしまい、
// CF Worker の Cache API が "Invalid URL" でこける。CF Worker は isolate 起動ごとに
// 状態を捨てるので、cache 自体を null にして毎回新規セッションで動作させる
// (cold start で少し遅くなるだけ)。
let ytPromise = null;
function getYT() {
  if (!ytPromise) {
    ytPromise = Innertube.create({
      cache: null,
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

  // Live: HLS manifest URL は cipher 不要、そのまま AVPlayer で再生可能。
  if (isLive && sd.hls_manifest_url) {
    return { url: sd.hls_manifest_url, kind: 'hls', isLive: true, title };
  }
  // ライブでも稀に dash_manifest_url のみのケースがあるので保険として返す。
  if (isLive && sd.dash_manifest_url) {
    return { url: sd.dash_manifest_url, kind: 'dash', isLive: true, title };
  }
  // VOD は CF Worker 内で signature decipher できない (前述の通り)。
  // iOS 側で iframe フォールバックさせる用に明示エラーを返す。
  return {
    error: 'vod_requires_iframe_fallback',
    isLive: false,
    title,
    hint: 'VOD signature decipher is not supported on CF Workers free tier; iOS should use iframe.'
  };
}

export default {
  async fetch(request) {
    try {
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
        console.error('extractor exception:', e);
        return jsonResponse({
          error: 'extractor exception',
          name: e?.name || null,
          message: e?.message || String(e),
          stack: e?.stack ? String(e.stack).split('\n').slice(0, 8).join(' | ') : null
        }, { status: 500 });
      }
    } catch (outer) {
      console.error('handler outer exception:', outer);
      return new Response(JSON.stringify({
        error: 'handler outer',
        name: outer?.name || null,
        message: outer?.message || String(outer),
        stack: outer?.stack ? String(outer.stack).split('\n').slice(0, 8).join(' | ') : null
      }), { status: 500, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }
  }
};
