// MultiView YouTube extractor (Cloudflare Worker, free tier)
//
// 2026-05 時点で YouTube は formats[*].url を出さなくなり、SABR + PoToken 必須化が
// 進んでいる。PoToken なしで成功するパターンは限定的だが、CF Worker のサーバ IP
// (iOS 端末より「綺麗」と評価されやすい) と複数 InnerTube クライアントの試行で
// ある程度カバーできる。失敗時は iOS 側で iframe フォールバックする。
//
// Usage:
//   GET https://<worker>.workers.dev/?v=<videoId>
//   GET https://<worker>.workers.dev/?v=<videoId>&prefer=live   (LIVE用にHLS優先)
//   GET https://<worker>.workers.dev/health
// Response:
//   200 { url, type: "hls"|"mp4", isLive, client, title?, quality? }
//   502 { error, sabrOnly?, lastClient? }

const CLIENTS = [
  {
    name: 'IOS',
    version: '20.19.2',
    key: 'AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc',
    headerName: '5',
    ua: 'com.google.ios.youtube/20.19.2 (iPhone16,2; U; CPU iOS 18_5_0 like Mac OS X; ja_JP)',
    extra: { deviceMake: 'Apple', deviceModel: 'iPhone16,2', osName: 'iPhone', osVersion: '18.5.0.22F76' }
  },
  {
    name: 'ANDROID',
    version: '20.19.35',
    key: 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w',
    headerName: '3',
    ua: 'com.google.android.youtube/20.19.35 (Linux; U; Android 15) gzip',
    extra: { androidSdkVersion: 35, deviceMake: 'Google', deviceModel: 'Pixel 9 Pro', osName: 'Android', osVersion: '15' }
  },
  {
    name: 'ANDROID_VR',
    version: '1.65.10',
    key: 'AIzaSyC4-Yqz5WHJZSn9pNwbZSgGtV_Le_3FfYY',
    headerName: '28',
    ua: 'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
    extra: { deviceMake: 'Oculus', deviceModel: 'Quest 3', androidSdkVersion: 32, osName: 'Android', osVersion: '12L' }
  },
  {
    name: 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
    version: '2.0',
    key: 'AIzaSyDCU8hByM-4DrUqRUYnGn-3llEO78bcxq8',
    headerName: '85',
    ua: 'Mozilla/5.0 (PlayStation; PlayStation 5/2.26) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0 Safari/605.1.15',
    extra: { clientScreen: 'EMBED' }
  }
];

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

async function callInnertube(client, videoId) {
  const body = {
    context: {
      client: {
        clientName: client.name,
        clientVersion: client.version,
        hl: 'ja',
        gl: 'JP',
        userAgent: client.ua,
        ...client.extra
      }
    },
    videoId,
    playbackContext: {
      contentPlaybackContext: {
        signatureTimestamp: 19500,
        html5Preference: 'HTML5_PREF_WANTS'
      }
    },
    contentCheckOk: true,
    racyCheckOk: true
  };
  const resp = await fetch(`https://www.youtube.com/youtubei/v1/player?key=${client.key}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'User-Agent': client.ua,
      'Origin': 'https://www.youtube.com',
      'X-YouTube-Client-Name': client.headerName,
      'X-YouTube-Client-Version': client.version,
      'Accept-Language': 'ja-JP,ja;q=0.9'
    },
    body: JSON.stringify(body)
  });
  if (!resp.ok) {
    return { ok: false, status: resp.status };
  }
  return { ok: true, data: await resp.json() };
}

function pickPlayableURL(streamingData) {
  if (!streamingData) return null;
  if (streamingData.hlsManifestUrl) {
    return { url: streamingData.hlsManifestUrl, type: 'hls', isLive: true };
  }
  const formats = streamingData.formats || [];
  const muxed = formats.filter(f => f.url && f.mimeType && f.mimeType.includes('video/'));
  if (muxed.length) {
    muxed.sort((a, b) => (b.height || 0) - (a.height || 0));
    const cap720 = muxed.find(f => (f.height || 0) <= 720) || muxed[muxed.length - 1];
    return { url: cap720.url, type: 'mp4', isLive: false, quality: cap720.qualityLabel };
  }
  return null;
}

export default {
  async fetch(request) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS });
    }
    const url = new URL(request.url);
    if (url.pathname === '/health') {
      return jsonResponse({ ok: true, clients: CLIENTS.map(c => c.name) });
    }
    const videoId = url.searchParams.get('v');
    if (!videoId || !/^[A-Za-z0-9_-]{6,32}$/.test(videoId)) {
      return jsonResponse({ error: 'missing or invalid v param' }, { status: 400 });
    }
    let lastErr = null;
    let sawSabr = false;
    for (const client of CLIENTS) {
      try {
        const result = await callInnertube(client, videoId);
        if (!result.ok) {
          lastErr = `${client.name}: HTTP ${result.status}`;
          continue;
        }
        const status = result.data.playabilityStatus?.status;
        if (status && status !== 'OK') {
          lastErr = `${client.name}: ${status} ${result.data.playabilityStatus?.reason || ''}`;
          continue;
        }
        const sd = result.data.streamingData;
        if (sd?.serverAbrStreamingUrl) sawSabr = true;
        const pick = pickPlayableURL(sd);
        if (pick) {
          return jsonResponse({
            ...pick,
            client: client.name,
            title: result.data.videoDetails?.title
          });
        }
        lastErr = `${client.name}: no playable URL`;
      } catch (e) {
        lastErr = `${client.name}: ${e.message || e}`;
      }
    }
    return jsonResponse({
      error: lastErr || 'all clients failed',
      sabrOnly: sawSabr,
      recommendIframe: true
    }, { status: 502 });
  }
};
