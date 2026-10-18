import {kickPusherURL, parseCentrifugoFrames, parseKickRealtimeApp} from '../kickRealtime';

describe('parseKickRealtimeApp', () => {
  it('picks the Centrifugo endpoint from the official negotiation response', () => {
    expect(parseKickRealtimeApp({
      data: {
        connections: [{credentials: {url: 'wss://realtime.us-west-2.platform.kick.com/connection/websocket'}, provider: 'centrifugo'}],
        mode: 'websocket',
      },
      message: 'success',
    })).toEqual({provider: 'centrifugo', url: 'wss://realtime.us-west-2.platform.kick.com/connection/websocket'});
  });

  it('still supports a negotiated Pusher app and skips incomplete entries', () => {
    const app = parseKickRealtimeApp({
      data: {
        mode: 'websocket',
        connections: [
          {provider: 'centrifugo', credentials: {}},
          {provider: 'pusher', credentials: {app_key: 'abc', cluster: 'us2'}},
        ],
      },
    });
    expect(app).toEqual({provider: 'pusher', appKey: 'abc', cluster: 'us2'});
    expect(kickPusherURL(app as {appKey: string; cluster: string})).toContain('wss://ws-us2.pusher.com/app/abc?');
  });

  it('rejects non-websocket modes', () => {
    expect(parseKickRealtimeApp({data: {mode: 'polling', connections: []}})).toBeNull();
    expect(parseKickRealtimeApp(null)).toBeNull();
  });
});

describe('parseCentrifugoFrames', () => {
  it('splits newline-delimited replies, pings and chat publications', () => {
    const frames = parseCentrifugoFrames([
      '{"id":1,"connect":{"client":"c","version":"6.9.7 PRO","expires":true,"ttl":2699,"ping":25,"pong":true}}',
      '{"id":2,"subscribe":{}}',
      '{}',
      '{"push":{"channel":"chatrooms.1.v2","pub":{"data":{"event":"App\\\\Events\\\\ChatMessageEvent","data":"{\\"id\\":\\"m1\\",\\"content\\":\\"www\\",\\"sender\\":{\\"username\\":\\"alice\\"}}"}}}}',
    ].join('\n'));
    expect(frames).toEqual([
      {kind: 'reply', id: 1, error: undefined, ttl: 2699},
      {kind: 'reply', id: 2, error: undefined, ttl: undefined},
      {kind: 'ping'},
      {
        kind: 'publication',
        channel: 'chatrooms.1.v2',
        event: 'App\\Events\\ChatMessageEvent',
        data: {id: 'm1', content: 'www', sender: {username: 'alice'}},
      },
    ]);
  });

  it('reports command errors and refresh TTLs', () => {
    expect(parseCentrifugoFrames('{"id":1,"error":{"code":109,"message":"token expired"}}'))
      .toEqual([{kind: 'reply', id: 1, error: 'token expired', ttl: undefined}]);
    expect(parseCentrifugoFrames('{"id":5,"refresh":{"expires":true,"ttl":2700}}'))
      .toEqual([{kind: 'reply', id: 5, error: undefined, ttl: 2700}]);
  });

  it('ignores malformed lines', () => {
    expect(parseCentrifugoFrames('not json\n{"push":{"channel":"x","pub":{"data":{}}}}')).toEqual([]);
  });
});
