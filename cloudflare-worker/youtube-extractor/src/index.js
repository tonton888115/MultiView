// MultiView YouTube live HLS resolver (Cloudflare Worker)
//
// Live playback uses the iOS InnerTube player response and returns only the
// HLS/DASH manifest URL that AVPlayer can consume. VOD cipher deciphering is
// intentionally not attempted in this worker.

const IOS_CLIENT_VERSION = '21.17.3';
const IOS_USER_AGENT =
  `com.google.ios.youtube/${IOS_CLIENT_VERSION} (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X; ja_JP)`;
const ANDROID_CLIENT_VERSION = '20.19.35';
const ANDROID_USER_AGENT =
  `com.google.android.youtube/${ANDROID_CLIENT_VERSION} (Linux; U; Android 15) gzip`;

const CLIENTS = [
  {
    label: 'ios',
    clientName: 'IOS',
    clientVersion: IOS_CLIENT_VERSION,
    headerClientName: '5',
    userAgent: IOS_USER_AGENT,
    extra: {
      deviceMake: 'Apple',
      deviceModel: 'iPhone16,2',
      osName: 'iOS',
      osVersion: '17.5.1.21F90'
    }
  },
  {
    label: 'android',
    clientName: 'ANDROID',
    clientVersion: ANDROID_CLIENT_VERSION,
    headerClientName: '3',
    userAgent: ANDROID_USER_AGENT,
    extra: {
      androidSdkVersion: 35,
      deviceMake: 'Google',
      deviceModel: 'Pixel 9 Pro',
      osName: 'Android',
      osVersion: '15'
    }
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
    headers: {
      ...CORS,
      'Content-Type': 'application/json; charset=utf-8',
      ...(init.headers || {})
    }
  });
}

function errorSummary(data, status) {
  const ps = data?.playabilityStatus || {};
  return {
    error: ps.status || `http_${status}`,
    reason: ps.reason || null,
    subreason: ps.subreason || null,
    playableInEmbed: ps.playableInEmbed ?? null,
    isLive: !!data?.videoDetails?.isLiveContent,
    title: data?.videoDetails?.title || ''
  };
}

async function fetchPlayer(videoId, client) {
  const body = {
    context: {
      client: {
        clientName: client.clientName,
        clientVersion: client.clientVersion,
        hl: 'ja',
        gl: 'JP',
        userAgent: client.userAgent,
        ...client.extra
      }
    },
    videoId,
    contentCheckOk: true,
    racyCheckOk: true,
    playbackContext: {
      contentPlaybackContext: {
        html5Preference: 'HTML5_PREF_WANTS'
      }
    }
  };

  const res = await fetch('https://youtubei.googleapis.com/youtubei/v1/player', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-YouTube-Client-Name': client.headerClientName,
      'X-YouTube-Client-Version': client.clientVersion,
      'User-Agent': client.userAgent,
      'Accept-Language': 'ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6'
    },
    body: JSON.stringify(body)
  });
  const data = await res.json().catch(() => null);
  return { status: res.status, data };
}

async function extractURL(videoId) {
  const attempts = [];
  for (const client of CLIENTS) {
    const { status, data } = await fetchPlayer(videoId, client);
    const summary = { client: client.label, status, ...errorSummary(data, status) };
    attempts.push(summary);
    if (!data || status < 200 || status >= 300) {
      continue;
    }

    const sd = data.streamingData || {};
    const details = data.videoDetails || {};
    const title = details.title || '';
    const isLive = !!details.isLiveContent || !!details.isLive;

    if (sd.hlsManifestUrl) {
      return {
        ok: true,
        url: sd.hlsManifestUrl,
        kind: 'hls',
        client: client.label,
        isLive,
        title,
        playabilityStatus: data.playabilityStatus?.status || null
      };
    }
    if (sd.dashManifestUrl) {
      return {
        ok: true,
        url: sd.dashManifestUrl,
        kind: 'dash',
        client: client.label,
        isLive,
        title,
        playabilityStatus: data.playabilityStatus?.status || null
      };
    }
    summary.hasStreamingData = !!data.streamingData;
    summary.hasAdaptiveFormats = Array.isArray(sd.adaptiveFormats) && sd.adaptiveFormats.length > 0;
    summary.hasSabr = !!sd.serverAbrStreamingUrl;
  }

  return {
    ok: false,
    error: 'no_manifest_url',
    attempts,
    hint: 'No hlsManifestUrl/dashManifestUrl in tested player responses.'
  };
}

export default {
  async fetch(request) {
    try {
      if (request.method === 'OPTIONS') return new Response(null, { headers: CORS });
      const url = new URL(request.url);
      if (url.pathname === '/health') {
        return jsonResponse({
          ok: true,
          version: '2026-05-28',
          engine: 'youtubei-player-hls',
          clients: CLIENTS.map(c => `${c.label}:${c.clientVersion}`)
        });
      }

      const videoId = url.searchParams.get('v');
      if (!videoId || !/^[A-Za-z0-9_-]{6,32}$/.test(videoId)) {
        return jsonResponse({ ok: false, error: 'missing_or_invalid_v' }, { status: 400 });
      }

      const result = await extractURL(videoId);
      return jsonResponse(result, { status: result.ok ? 200 : 502 });
    } catch (e) {
      return jsonResponse({
        ok: false,
        error: 'worker_exception',
        name: e?.name || null,
        message: e?.message || String(e),
        stack: e?.stack ? String(e.stack).split('\n').slice(0, 8).join(' | ') : null
      }, { status: 500 });
    }
  }
};
