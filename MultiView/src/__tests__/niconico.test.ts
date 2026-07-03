import {
  isNiconicoEndedWatchPage,
  isNiconicoSupportNotification,
  niconicoNativeBlockReason,
  niconicoPostCommentScript,
  niconicoSessionScript,
  niconicoSupportPresentation,
  parseNiconicoWatchData,
} from '../niconico';
import {TWITCASTING_STREAM_PRIORITY, pickTwitcastingHlsUrl} from '../twitcasting';

// data-props は HTML エンティティ化された JSON。テストでは引用符だけ &quot; にする。
function dataProps(obj: unknown): string {
  return JSON.stringify(obj).replace(/"/g, '&quot;');
}

describe('niconico watch-data parsing (iOS NiconicoPlayer parity)', () => {
  it('keeps generic visitor notices out of comments and uses the iOS support notification filter', () => {
    expect(isNiconicoSupportNotification(1, '来場者が入室しました')).toBe(false);
    expect(isNiconicoSupportNotification(7, 'サポーターが参加しました')).toBe(true);
    expect(isNiconicoSupportNotification(undefined, 'レベルアップしました')).toBe(true);
  });

  it('routes Nico support events only to the dedicated overlay and honors each iOS toggle', () => {
    const settings = {
      showGiftEffects: false,
      niconicoShowGift: true,
      niconicoShowNicoad: true,
      niconicoShowNotification: true,
    };
    expect(niconicoSupportPresentation('gift', settings)).toBe('hidden');
    expect(niconicoSupportPresentation('nicoad', settings)).toBe('overlay');
    expect(niconicoSupportPresentation('notification', settings)).toBe('overlay');
    expect(niconicoSupportPresentation('notification', {...settings, niconicoShowNotification: false})).toBe('hidden');
  });
  it('reads the new pageContents.playerParams.wsEndPoint shape', () => {
    const props = {
      pageContents: {watchInformation: {playerParams: {wsEndPoint: {url: 'wss://a.example/ws'}}}},
      constants: {requestInfo: {frontendId: 12}},
    };
    const html = `<script id="embedded-data" data-props="${dataProps(props)}"></script>`;
    expect(parseNiconicoWatchData(html)).toEqual({wsUrl: 'wss://a.example/ws', frontendId: '12'});
  });

  it('reads the legacy site.relive.webSocketUrl shape', () => {
    const props = {site: {relive: {webSocketUrl: 'wss://b.example/ws'}, frontendId: 9}};
    const html = `<script id="embedded-data" data-props="${dataProps(props)}"></script>`;
    expect(parseNiconicoWatchData(html)).toEqual({wsUrl: 'wss://b.example/ws', frontendId: '9'});
  });

  it('returns null when no websocket url is present', () => {
    expect(parseNiconicoWatchData('<html>nope</html>')).toBeNull();
    const props = {site: {name: 'x'}};
    expect(parseNiconicoWatchData(`<div id="embedded-data" data-props="${dataProps(props)}"></div>`)).toBeNull();
  });

  it('marks ticket-only programs without a ticket as native-blocked', () => {
    const props = {
      site: {relive: {webSocketUrl: 'wss://ticket.example/ws'}, frontendId: 9},
      programWatch: {condition: {payment: 'Ticket'}},
      userProgramWatch: {payment: {hasTicket: false}},
    };
    const html = `<script id="embedded-data" data-props="${dataProps(props)}"></script>`;

    expect(parseNiconicoWatchData(html)).toEqual({
      wsUrl: 'wss://ticket.example/ws',
      frontendId: '9',
      nativeBlockReason: {reason: 'ticket', message: 'チケット購入者限定です'},
    });
    expect(niconicoNativeBlockReason(props)).toEqual({reason: 'ticket', message: 'チケット購入者限定です'});
  });

  it('does not block native playback for ticketed programs once the viewer has a ticket', () => {
    const props = {
      site: {relive: {webSocketUrl: 'wss://ticket.example/ws'}},
      programWatch: {condition: {payment: 'Ticket'}},
      userProgramWatch: {payment: {hasTicket: true}},
    };

    expect(niconicoNativeBlockReason(props)).toBeNull();
  });

  it('does not block anonymous programs when logged-out viewers can watch', () => {
    const props = {
      site: {relive: {webSocketUrl: 'wss://anonymous.example/ws'}},
      user: {isLoggedIn: false, login_status: 'not_login', member_status: null},
      programWatch: {condition: {needLogin: false}},
      userProgramWatch: {canWatch: true, payment: {hasTicket: false}, isCountryRestrictionTarget: false},
    };

    expect(niconicoNativeBlockReason(props)).toBeNull();
  });

  it('marks logged-out viewer-only programs as native-blocked', () => {
    const props = {
      site: {relive: {webSocketUrl: 'wss://login.example/ws'}, frontendId: 9},
      user: {isLoggedIn: false, login_status: 'not_login', member_status: null},
      programWatch: {condition: {needLogin: false}},
      userProgramWatch: {canWatch: false, payment: {hasTicket: false}},
    };
    const html = `<script id="embedded-data" data-props="${dataProps(props)}"></script>`;

    expect(parseNiconicoWatchData(html)).toEqual({
      wsUrl: 'wss://login.example/ws',
      frontendId: '9',
      nativeBlockReason: {reason: 'login', message: 'ログインが必要です'},
    });
    expect(niconicoSessionScript('lv123', 'abr')).toContain('userWatch&&userWatch.canWatch===false');
  });

  it('does not reject an authenticated viewer only because the program requires login', () => {
    const props = {
      user: {isLoggedIn: true, login_status: 'login', member_status: 'premium'},
      programWatch: {condition: {needLogin: true}},
      userProgramWatch: {canWatch: true},
    };

    expect(niconicoNativeBlockReason(props)).toBeNull();
    expect(niconicoSessionScript('lv123', 'abr')).toContain('condition.needLogin===true&&isLoggedOut');
  });
});

describe('niconico ended detection (iOS NiconicoPlayer parity)', () => {
  it('detects explicit ended state in watch data only', () => {
    expect(isNiconicoEndedWatchPage(`<script id="embedded-data" data-props="${dataProps({program: {status: 'ENDED'}})}"></script>`)).toBe(true);
    expect(isNiconicoEndedWatchPage('<div data-program-status="ENDED"></div>')).toBe(true);
  });

  it('does not treat unrelated page text as an ended program', () => {
    expect(isNiconicoEndedWatchPage('<footer>次回の放送をリクエストしませんか</footer>')).toBe(false);
    expect(isNiconicoEndedWatchPage('<script>{"status":"onair","endTime":"2026-12-27T00:00:00+09:00"}</script>')).toBe(false);
    expect(isNiconicoEndedWatchPage(`<script id="embedded-data" data-props="${dataProps({
      program: {status: 'ON_AIR'},
      recommendations: [{status: 'ENDED'}],
    })}"></script>`)).toBe(false);
  });

  it('keeps exactly one current websocket generation during bridge reconnects', () => {
    const script = niconicoSessionScript('lv123', 'abr');
    expect(script).toContain('socketGeneration=0, activeSocket=null');
    expect(script).toContain('activeSocket===sock&&generation===socketGeneration');
    expect(script).toContain('sock.onopen=null; sock.onmessage=null; sock.onerror=null; sock.onclose=null;');
    expect(script).toContain("sock.onclose=function(){ recoverSocket('ws closed'); };");
    expect(script).not.toContain("sock.onclose=function(){ post({type:'niconicoEnded'}); };");
  });

  it('ignores a stale websocket close after a replacement reconnect was scheduled', async () => {
    jest.useFakeTimers();
    const sockets: Array<any> = [];
    const posts: Array<any> = [];
    class FakeWebSocket {
      onopen: (() => void) | null = null;
      onmessage: ((event: {data: string}) => void) | null = null;
      onerror: (() => void) | null = null;
      onclose: (() => void) | null = null;
      send = jest.fn();
      close = jest.fn();

      constructor(_url: string) {
        sockets.push(this);
      }
    }
    class FakeAbortController {
      signal = {};
      abort = jest.fn();
    }
    class FakeTextDecoder {
      decode(): string {
        return '';
      }
    }
    const props = {site: {relive: {webSocketUrl: 'wss://example.test/ws'}, frontendId: 9}};
    const html = `<script id="embedded-data" data-props="${dataProps(props)}"></script>`;
    const fetchMock = jest.fn().mockResolvedValue({ok: true, status: 200, text: async () => html});
    const run = new Function(
      'window', 'fetch', 'WebSocket', 'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval',
      'TextDecoder', 'AbortController',
      niconicoSessionScript('lv123', 'abr'),
    );
    const flushPromises = async () => {
      for (let index = 0; index < 6; index += 1) {
        await Promise.resolve();
      }
    };

    run(
      {ReactNativeWebView: {postMessage: (value: string) => posts.push(JSON.parse(value))}},
      fetchMock,
      FakeWebSocket,
      setTimeout,
      clearTimeout,
      setInterval,
      clearInterval,
      FakeTextDecoder,
      FakeAbortController,
    );
    await flushPromises();
    expect(sockets).toHaveLength(1);

    const staleClose = sockets[0].onclose!;
    sockets[0].onerror!();
    expect(sockets[0].onclose).toBeNull();
    staleClose();
    jest.advanceTimersByTime(3000);
    await flushPromises();
    expect(sockets).toHaveLength(2);
    jest.advanceTimersByTime(3000);
    await flushPromises();
    expect(sockets).toHaveLength(2);
    expect(posts.filter(post => post.type === 'niconicoError')).toHaveLength(1);
    jest.useRealTimers();
  });

  it('keeps retrying after the initial watch-page retry budget is exhausted', async () => {
    jest.useFakeTimers();
    const posts: Array<any> = [];
    const fetchMock = jest.fn().mockResolvedValue({
      ok: true,
      status: 200,
      text: async () => '<html></html>',
    });
    class FakeTextDecoder {
      decode(): string {
        return '';
      }
    }
    class FakeAbortController {
      signal = {};
      abort = jest.fn();
    }
    class UnexpectedWebSocket {
      constructor() {
        throw new Error('no websocket URL expected');
      }
    }
    const run = new Function(
      'window', 'fetch', 'WebSocket', 'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval',
      'TextDecoder', 'AbortController',
      niconicoSessionScript('lv123', 'abr'),
    );
    const flushPromises = async () => {
      for (let index = 0; index < 6; index += 1) {
        await Promise.resolve();
      }
    };

    run(
      {ReactNativeWebView: {postMessage: (value: string) => posts.push(JSON.parse(value))}},
      fetchMock,
      UnexpectedWebSocket,
      setTimeout,
      clearTimeout,
      setInterval,
      clearInterval,
      FakeTextDecoder,
      FakeAbortController,
    );
    await flushPromises();
    for (let retry = 0; retry < 3; retry += 1) {
      jest.advanceTimersByTime(1500);
      await flushPromises();
    }
    expect(fetchMock).toHaveBeenCalledTimes(4);
    expect(posts).toContainEqual({type: 'niconicoError', message: 'ws url not found'});

    jest.advanceTimersByTime(9_999);
    await flushPromises();
    expect(fetchMock).toHaveBeenCalledTimes(4);
    jest.advanceTimersByTime(1);
    await flushPromises();
    expect(fetchMock).toHaveBeenCalledTimes(5);
    jest.useRealTimers();
  });

  it('replaces stale NDGR readers and escalates persistent comment stalls', () => {
    const script = niconicoSessionScript('lv123', 'abr');
    expect(() => new Function(script)).not.toThrow();
    expect(script).toContain("makeController(){ return typeof AbortController!=='undefined'?new AbortController():null; }");
    expect(script).toContain('nicoViewGeneration++');
    expect(script).toContain("viewUri===nicoViewUri&&nicoViewController");
    expect(script).toContain("type:'niconicoCommentBridgeError'");
    expect(script).toContain('stopNdgr(); reconnectSession(1000)');
    expect(script).toContain('nicoFailures>=3||sinceSuccess>20000||sinceReconnect>12000');
    expect(script).toContain('if(attempt<4)');
  });

  it('injects comment text without interpolating executable source', () => {
    const calls: Array<[string, string]> = [];
    const posts: Array<any> = [];
    const window = {
      __mvNicoPostComment: (requestId: string, text: string) => calls.push([requestId, text]),
      ReactNativeWebView: {postMessage: (value: string) => posts.push(JSON.parse(value))},
    };
    const text = `quote ' " \\ newline\n</script> \u2028`;
    const script = niconicoPostCommentScript('request-1', text);

    expect(() => new Function('window', script)(window)).not.toThrow();
    expect(calls).toEqual([['request-1', text]]);
    expect(posts).toEqual([]);
    expect(script).toContain('window.__mvNicoPostComment');
    expect(script).toContain('\\u2028');
  });

  it('posts a comment through the active watch websocket and reports the correlated result', async () => {
    const sockets: Array<any> = [];
    const posts: Array<any> = [];
    class FakeWebSocket {
      readyState = 0;
      onopen: (() => void) | null = null;
      onmessage: ((event: {data: string}) => void) | null = null;
      onerror: (() => void) | null = null;
      onclose: (() => void) | null = null;
      send = jest.fn();
      close = jest.fn();

      constructor(_url: string) {
        sockets.push(this);
      }
    }
    class FakeAbortController {
      signal = {};
      abort = jest.fn();
    }
    class FakeTextDecoder {
      decode(): string {
        return '';
      }
    }
    const props = {
      site: {relive: {webSocketUrl: 'wss://example.test/ws'}, frontendId: 9},
      user: {isLoggedIn: true, login_status: 'login', member_status: 'general'},
    };
    const html = `<script id="embedded-data" data-props="${dataProps(props)}"></script>`;
    const fetchMock = jest.fn().mockResolvedValue({ok: true, status: 200, text: async () => html});
    const window: any = {
      ReactNativeWebView: {postMessage: (value: string) => posts.push(JSON.parse(value))},
    };
    const run = new Function(
      'window', 'fetch', 'WebSocket', 'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval',
      'TextDecoder', 'AbortController',
      niconicoSessionScript('lv123', 'abr'),
    );
    const flushPromises = async () => {
      for (let index = 0; index < 6; index += 1) {
        await Promise.resolve();
      }
    };

    run(
      window,
      fetchMock,
      FakeWebSocket,
      setTimeout,
      clearTimeout,
      setInterval,
      clearInterval,
      FakeTextDecoder,
      FakeAbortController,
    );
    await flushPromises();
    expect(sockets).toHaveLength(1);
    sockets[0].readyState = 1;
    sockets[0].onopen!();
    sockets[0].onmessage!({data: JSON.stringify({type: 'stream', data: {uri: 'https://example.test/live.m3u8'}})});

    window.__mvNicoPostComment('comment-1', ' hello ');
    const sent = sockets[0].send.mock.calls.map((call: [string]) => JSON.parse(call[0]));
    expect(sent).toContainEqual({
      type: 'postComment',
      data: {text: 'hello', vpos: expect.any(Number)},
    });
    expect(posts).toContainEqual({type: 'niconicoCommentPostResult', requestId: 'comment-1', ok: true});

    sockets[0].readyState = 3;
    window.__mvNicoPostComment('comment-2', 'retry');
    expect(posts).toContainEqual(expect.objectContaining({
      type: 'niconicoCommentPostResult',
      requestId: 'comment-2',
      ok: false,
      message: expect.stringContaining('準備できていません'),
    }));
    expect(niconicoSessionScript('lv123', 'abr')).toContain("commentLoginState==='out'");
  });
});

describe('twitcasting HLS stream priority', () => {
  it.each(TWITCASTING_STREAM_PRIORITY)('returns the %s stream when it is the best available priority', key => {
    const streams = Object.fromEntries(
      TWITCASTING_STREAM_PRIORITY.map(priority => [priority, priority === key ? `https://example.com/${priority}.m3u8` : '']),
    );
    expect(pickTwitcastingHlsUrl(streams)).toBe(`https://example.com/${key}.m3u8`);
  });

  it('returns any stream key when no priority key is present', () => {
    expect(pickTwitcastingHlsUrl({other: 'https://example.com/other.m3u8'})).toBe('https://example.com/other.m3u8');
  });

  it('returns null for empty or null streams', () => {
    expect(pickTwitcastingHlsUrl({})).toBeNull();
    expect(pickTwitcastingHlsUrl(null)).toBeNull();
  });
});
