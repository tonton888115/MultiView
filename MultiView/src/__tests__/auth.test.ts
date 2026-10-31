import {completeOAuthRedirect, defaultAuthState, postStreamComment, type AuthState} from '../auth';
import {clearLiveYouTubeVideoIDCache} from '../playback';

type MockResponse = {ok: boolean; status: number; url?: string; json: () => Promise<unknown>; text: () => Promise<string>};

const originalFetch = globalThis.fetch;

function respond(body: unknown, init: {ok?: boolean; status?: number} = {}): MockResponse {
  return {
    ok: init.ok ?? true,
    status: init.status ?? 200,
    json: async () => body,
    text: async () => JSON.stringify(body),
  };
}

function installFetch(handler: (url: string, init?: {method?: string}) => MockResponse): jest.Mock {
  const mock = jest.fn(async (url: string, init?: {method?: string}) => handler(url, init));
  (globalThis as {fetch: unknown}).fetch = mock;
  return mock;
}

afterEach(() => {
  (globalThis as {fetch: unknown}).fetch = originalFetch;
  clearLiveYouTubeVideoIDCache();
});

function twitchAuth(expiresAt: number): AuthState {
  return {
    ...defaultAuthState,
    twitch: {
      config: {clientId: 'client', redirectURI: defaultAuthState.twitch.config.redirectURI},
      token: {accessToken: 'token', userID: 'me', expiresAt},
    },
  };
}

describe('Twitch login lifetime', () => {
  it('uses the validate expires_in instead of assuming one hour', async () => {
    installFetch(() => respond({user_id: '42', expires_in: 5184000}));
    const next = await completeOAuthRedirect(
      defaultAuthState,
      {service: 'twitch', state: 's', redirectURI: 'x'},
      'multiview://twitch-oauth#access_token=abc&state=s',
    );
    const token = next.twitch.token!;
    expect(token.userID).toBe('42');
    expect(token.expiresAt - Date.now()).toBeGreaterThan(3600 * 24 * 59 * 1000);
  });

  it('keeps using an "expired" token when Twitch still validates it', async () => {
    const calls: string[] = [];
    installFetch((url, init) => {
      calls.push(`${init?.method ?? 'GET'} ${url}`);
      if (url.includes('/oauth2/validate')) {
        return respond({user_id: 'me', expires_in: 3600 * 24});
      }
      if (url.includes('/helix/users')) {
        return respond({data: [{id: 'broadcaster'}]});
      }
      return respond({data: [{message_id: 'm', is_sent: true}]});
    });
    const next = await postStreamComment(twitchAuth(Date.now() - 1000), {id: 'twitch:x', platform: 'twitch', channel: 'x'}, 'hi');
    expect(next.twitch.token!.expiresAt).toBeGreaterThan(Date.now());
    expect(calls.some(call => call.startsWith('POST https://api.twitch.tv/helix/chat/messages'))).toBe(true);
  });

  it('reports messages that Twitch accepted over HTTP but dropped', async () => {
    installFetch(url => {
      if (url.includes('/helix/users')) {
        return respond({data: [{id: 'broadcaster'}]});
      }
      return respond({data: [{message_id: '', is_sent: false, drop_reason: {code: 'msg_rejected', message: 'AutoMod'}}]});
    });
    await expect(
      postStreamComment(twitchAuth(Date.now() + 60000), {id: 'twitch:x', platform: 'twitch', channel: 'x'}, 'hi'),
    ).rejects.toThrow('AutoMod');
  });
});
