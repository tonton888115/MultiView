// Optional CORS proxy for MultiView (Kick / TwitCasting chat lookups).
//
// Deploy free at https://workers.cloudflare.com :
//   1. Create a Worker, paste this file, Deploy.
//   2. Copy the URL, e.g. https://multiview-proxy.<you>.workers.dev
//   3. In the app's Settings, set "CORSプロキシ" to:  https://multiview-proxy.<you>.workers.dev/?url=
//
// Note: Kick sits behind Cloudflare bot protection, so even a Worker may sometimes
// get challenged. TwitCasting generally works through this proxy.

const ALLOWED_HOSTS = [
  'kick.com',
  'twitcasting.tv',
  'frontendapi.twitcasting.tv',
];

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
  'Access-Control-Allow-Headers': '*',
};

export default {
  async fetch(request) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS });
    }

    const target = new URL(request.url).searchParams.get('url');
    if (!target) {
      return new Response('missing ?url=', { status: 400, headers: CORS });
    }

    let t;
    try {
      t = new URL(target);
    } catch {
      return new Response('bad url', { status: 400, headers: CORS });
    }
    if (!ALLOWED_HOSTS.includes(t.hostname)) {
      return new Response('host not allowed', { status: 403, headers: CORS });
    }

    const init = {
      method: request.method,
      headers: {
        Accept: 'application/json',
        'User-Agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15',
      },
    };
    if (request.method === 'POST') {
      init.headers['Content-Type'] =
        request.headers.get('Content-Type') || 'application/x-www-form-urlencoded';
      init.body = await request.text();
    }

    try {
      const resp = await fetch(target, init);
      const body = await resp.text();
      return new Response(body, {
        status: resp.status,
        headers: {
          ...CORS,
          'Content-Type': resp.headers.get('Content-Type') || 'application/json',
        },
      });
    } catch (e) {
      return new Response('upstream error: ' + e, { status: 502, headers: CORS });
    }
  },
};
