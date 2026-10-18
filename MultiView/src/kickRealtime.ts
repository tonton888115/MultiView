// Kick のチャット realtime 接続。2026-10 に Pusher(ws-us2 / 32cbd69e…)は
// 「App key not in this cluster」で即切断されるようになり、公式 Web は
// web.kick.com の交渉 API が返す provider(現状 Centrifugo)へ接続している。
// 公式と同じく交渉結果を正とし、pusher が返れば従来の Pusher で接続する。

export type KickRealtimeApp =
  | {provider: 'centrifugo'; url: string}
  | {provider: 'pusher'; appKey: string; cluster: string};

// 交渉 API 自体が落ちている時の既定値(2026-10 時点の公式応答)。
export const kickRealtimeDefaultApp: KickRealtimeApp = {
  provider: 'centrifugo',
  url: 'wss://realtime.us-east-1.platform.kick.com/connection/websocket',
};

// Centrifugo は Origin を検査する(kick.com / 同一ホスト以外は 403)。
export const kickRealtimeOrigin = 'https://kick.com';

const kickWebAPI = 'https://web.kick.com/api/v1/realtime';

export type CentrifugoFrame =
  | {kind: 'ping'}
  | {kind: 'reply'; id: number; error?: string; ttl?: number}
  | {kind: 'publication'; channel: string; event: string; data: any};

// 公式 Web の getRealtimeApp と同じ選び方: mode=websocket の connections を先頭から見て、
// 必要な credentials が揃った最初のものを使う。
export function parseKickRealtimeApp(json: any): KickRealtimeApp | null {
  const data = json?.data ?? json;
  if (data?.mode !== 'websocket' || !Array.isArray(data?.connections)) {
    return null;
  }
  for (const connection of data.connections) {
    const credentials = connection?.credentials ?? {};
    if (connection?.provider === 'centrifugo' && typeof credentials.url === 'string' && credentials.url) {
      return {provider: 'centrifugo', url: credentials.url};
    }
    if (
      connection?.provider === 'pusher'
      && typeof credentials.app_key === 'string' && credentials.app_key
      && typeof credentials.cluster === 'string' && credentials.cluster
    ) {
      return {provider: 'pusher', appKey: credentials.app_key, cluster: credentials.cluster};
    }
  }
  return null;
}

export function kickPusherURL(app: {appKey: string; cluster: string}): string {
  return `wss://ws-${app.cluster}.pusher.com/app/${app.appKey}?protocol=7&client=android-native&version=1.0&flash=false`;
}

export function kickRealtimeClientId(): string {
  const hex = (length: number) => Array.from({length}, () => Math.floor(Math.random() * 16).toString(16)).join('');
  return `${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}`;
}

export async function negotiateKickRealtimeApp(channelId: string, clientId: string): Promise<KickRealtimeApp> {
  const response = await fetch(`${kickWebAPI}/channels/${encodeURIComponent(channelId)}/chat/connection`, {
    method: 'POST',
    headers: {'Content-Type': 'application/json', Accept: 'application/json', Origin: kickRealtimeOrigin},
    body: JSON.stringify({
      client: {id: clientId, type: 'web'},
      capabilities: {accepted_providers: [{provider: 'pusher'}, {provider: 'centrifugo'}]},
    }),
  });
  if (!response.ok) {
    throw new Error(`Kick realtime交渉失敗 HTTP ${response.status}`);
  }
  const app = parseKickRealtimeApp(await response.json());
  if (!app) {
    throw new Error('Kick realtime接続先を取得できません');
  }
  return app;
}

export async function fetchKickCentrifugoToken(clientId: string): Promise<string> {
  const response = await fetch(`${kickWebAPI}/auth/connection`, {
    method: 'POST',
    headers: {'Content-Type': 'application/json', Accept: 'application/json', Origin: kickRealtimeOrigin},
    body: JSON.stringify({client_id: clientId}),
  });
  if (!response.ok) {
    throw new Error(`Kickコメント認証失敗 HTTP ${response.status}`);
  }
  const json = await response.json();
  const token = json?.data?.token;
  if (typeof token !== 'string' || !token) {
    throw new Error('Kickコメント認証トークンを取得できません');
  }
  return token;
}

// Centrifugo JSON プロトコルは 1 フレームに改行区切りで複数メッセージを載せる。
// `{}` はサーバー ping(pong:true なので `{}` を返す必要がある)。
// publication の data は公式 envelope {event, data}。data は JSON 文字列のことがある。
export function parseCentrifugoFrames(text: string): CentrifugoFrame[] {
  const frames: CentrifugoFrame[] = [];
  text.split('\n').forEach(line => {
    const trimmed = line.trim();
    if (!trimmed) {
      return;
    }
    let message: any;
    try {
      message = JSON.parse(trimmed);
    } catch {
      return;
    }
    if (!message || typeof message !== 'object') {
      return;
    }
    if (Object.keys(message).length === 0) {
      frames.push({kind: 'ping'});
      return;
    }
    if (typeof message.id === 'number') {
      const result = message.connect ?? message.refresh;
      frames.push({
        kind: 'reply',
        id: message.id,
        error: message.error ? String(message.error.message ?? message.error.code ?? 'error') : undefined,
        ttl: result?.expires && typeof result.ttl === 'number' ? result.ttl : undefined,
      });
      return;
    }
    const push = message.push;
    const envelope = push?.pub?.data;
    if (typeof envelope?.event !== 'string') {
      return;
    }
    let data = envelope.data;
    if (typeof data === 'string') {
      try {
        data = JSON.parse(data);
      } catch {
        // 文字列のまま渡す
      }
    }
    frames.push({kind: 'publication', channel: String(push.channel ?? ''), event: envelope.event, data});
  });
  return frames;
}
