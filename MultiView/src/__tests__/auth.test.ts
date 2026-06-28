import {
  authStatus,
  completeOAuthRedirect,
  createOAuthURLSingleFlight,
  defaultAuthState,
  deviceOAuthErrorDisposition,
  hasUsableAuthSession,
  isOAuthRedirectForPending,
  maintainAuthSessions,
  mergeAuthMaintenanceSnapshot,
  nextDeviceOAuthPollInterval,
  oauthCompletionErrorDisposition,
  pollTwitchDeviceToken,
  postStreamComment,
  requestTwitchDeviceCode,
  sanitizeAuthState,
  sanitizePendingDeviceOAuth,
  sanitizePendingOAuth,
  type AuthState,
  type PendingDeviceOAuth,
} from '../auth';
import type {StreamItem} from '../types';

const originalFetch = globalThis.fetch;

function response(json: unknown, ok = true, status = 200) {
  return {
    ok,
    status,
    json: jest.fn().mockResolvedValue(json),
    text: jest.fn().mockResolvedValue(typeof json === 'string' ? json : JSON.stringify(json)),
  } as unknown as Response;
}

function twitchAuth(token?: AuthState['twitch']['token']): AuthState {
  return {
    ...defaultAuthState,
    twitch: {
      config: {...defaultAuthState.twitch.config, clientId: 'client-id'},
      token,
    },
  };
}

afterEach(() => {
  globalThis.fetch = originalFetch;
  jest.restoreAllMocks();
});

describe('proactive auth maintenance', () => {
  it('does not overwrite a login completed while maintenance was in flight', () => {
    const base = defaultAuthState;
    const current: AuthState = {
      ...base,
      youtube: {
        ...base.youtube,
        token: {accessToken: 'new-login', refreshToken: 'new-refresh', expiresAt: Date.now() + 3600_000},
      },
    };
    const maintained: AuthState = {
      ...base,
      kick: {
        ...base.kick,
        token: {accessToken: 'maintained-kick', refreshToken: 'kick-refresh', expiresAt: Date.now() + 3600_000},
      },
    };

    const merged = mergeAuthMaintenanceSnapshot(base, current, maintained);

    expect(merged.kick.token?.accessToken).toBe('maintained-kick');
    expect(merged.youtube.token?.accessToken).toBe('new-login');
  });

  it('refreshes an expired Kick session without waiting for a comment send', async () => {
    const fetchMock = jest.fn().mockResolvedValue(response({
      access_token: 'kick-access-2',
      refresh_token: 'kick-refresh-2',
      expires_in: 3600,
    }));
    globalThis.fetch = fetchMock as typeof fetch;
    const auth: AuthState = {
      ...defaultAuthState,
      kick: {
        config: {...defaultAuthState.kick.config, clientId: 'kick-client'},
        token: {
          accessToken: 'kick-expired',
          refreshToken: 'kick-refresh-1',
          expiresAt: Date.now() - 1,
        },
      },
    };
    const onAuthUpdated = jest.fn();

    const next = await maintainAuthSessions(auth, onAuthUpdated);

    expect(next.kick.token).toMatchObject({
      accessToken: 'kick-access-2',
      refreshToken: 'kick-refresh-2',
    });
    expect(onAuthUpdated).toHaveBeenCalledWith(next);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('coalesces concurrent refreshes so rotating refresh tokens are used once', async () => {
    let resolveFetch!: (value: Response) => void;
    const fetchMock = jest.fn().mockImplementation(() => new Promise<Response>(resolve => {
      resolveFetch = resolve;
    }));
    globalThis.fetch = fetchMock as typeof fetch;
    const auth: AuthState = {
      ...defaultAuthState,
      kick: {
        config: {...defaultAuthState.kick.config, clientId: 'kick-client'},
        token: {
          accessToken: 'kick-expired',
          refreshToken: 'kick-refresh-1',
          expiresAt: Date.now() - 1,
        },
      },
    };

    const first = maintainAuthSessions(auth);
    const second = maintainAuthSessions(auth);
    await Promise.resolve();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    resolveFetch(response({access_token: 'kick-access-2', refresh_token: 'kick-refresh-2', expires_in: 3600}));

    const [firstResult, secondResult] = await Promise.all([first, second]);
    expect(firstResult.kick.token?.refreshToken).toBe('kick-refresh-2');
    expect(secondResult.kick.token?.refreshToken).toBe('kick-refresh-2');
  });

  it('uses the provider documented 180-day TwitCasting implicit lifetime fallback', async () => {
    const before = Date.now();
    const next = await completeOAuthRedirect(defaultAuthState, {
      service: 'twitcasting',
      state: 'state',
      redirectURI: 'multiview://twitcasting-oauth',
    }, 'multiview://twitcasting-oauth#access_token=tc-token&state=state');

    expect(next.twitcasting.token?.expiresAt).toBeGreaterThan(before + 170 * 24 * 3600 * 1000);
  });
});

describe('auth lifecycle', () => {
  it('runs the same OAuth redirect only once while completion is in flight and releases afterward', async () => {
    const gate = createOAuthURLSingleFlight();
    let finish: (() => void) | undefined;
    const task = jest.fn(() => new Promise<void>(resolve => {
      finish = resolve;
    }));

    const first = gate.run('multiview://kick?code=one', task);
    await expect(gate.run('multiview://kick?code=one', task)).resolves.toBe(false);
    expect(task).toHaveBeenCalledTimes(1);
    finish?.();
    await expect(first).resolves.toBe(true);
    await expect(gate.run('multiview://kick?code=two', async () => undefined)).resolves.toBe(true);
  });

  it('accepts only the callback route belonging to the pending OAuth service', () => {
    expect(isOAuthRedirectForPending({
      service: 'kick',
      state: 'state',
      verifier: 'pkce',
      redirectURI: 'https://tonton888115.github.io/MultiView/kick-oauth.html',
    }, 'multiview://kick-oauth?code=one&state=state')).toBe(true);
    expect(isOAuthRedirectForPending({
      service: 'kick',
      state: 'state',
      verifier: 'pkce',
      redirectURI: 'https://tonton888115.github.io/MultiView/kick-oauth.html',
    }, 'multiview://twitcasting-oauth?code=stale')).toBe(false);
    expect(isOAuthRedirectForPending({
      service: 'twitcasting',
      state: 'state',
      redirectURI: 'multiview://twitcasting-oauth',
    }, 'multiview://twitcasting-oauth#access_token=one&state=state')).toBe(true);
  });

  it('keeps normal OAuth pending on transient exchange failure but rejects a state mismatch terminally', async () => {
    const auth: AuthState = {
      ...defaultAuthState,
      kick: {
        config: {...defaultAuthState.kick.config, clientId: 'client-id'},
      },
    };
    const pending = {
      service: 'kick' as const,
      state: 'state',
      verifier: 'verifier',
      redirectURI: 'https://tonton888115.github.io/MultiView/kick-oauth.html',
    };
    globalThis.fetch = jest.fn().mockResolvedValue(response({message: 'temporarily unavailable'}, false, 503)) as typeof fetch;

    const transient = await completeOAuthRedirect(auth, pending, 'multiview://kick-oauth?code=one&state=state')
      .catch(error => error);
    const terminal = await completeOAuthRedirect(auth, pending, 'multiview://kick-oauth?code=one&state=wrong')
      .catch(error => error);

    expect(oauthCompletionErrorDisposition(transient)).toBe('retry');
    expect(oauthCompletionErrorDisposition(terminal)).toBe('terminal');
  });

  it('sanitizes restored token and pending OAuth state without trusting malformed expiry values', () => {
    const auth = sanitizeAuthState({
      twitch: {
        config: {clientId: 'client-id', redirectURI: 'multiview://callback'},
        token: {accessToken: 'access', refreshToken: 'refresh', expiresAt: 'not-a-number', scope: ['a', 'b']},
      },
    });
    expect(auth.twitch.token).toEqual({
      accessToken: 'access',
      refreshToken: 'refresh',
      expiresAt: 0,
      userID: undefined,
      scope: 'a b',
    });
    expect(authStatus(auth, 'twitch')).toBe('ログイン済み（自動更新）');
    expect(hasUsableAuthSession(auth, 'twitch')).toBe(true);

    const expiredWithoutRefresh = twitchAuth({accessToken: 'expired', expiresAt: Date.now() - 1});
    expect(authStatus(expiredWithoutRefresh, 'twitch')).toBe('期限切れ');
    expect(hasUsableAuthSession(expiredWithoutRefresh, 'twitch')).toBe(false);

    expect(sanitizePendingOAuth({service: 'kick', state: 'state', verifier: 'pkce', redirectURI: 'multiview://kick'}))
      .toEqual({service: 'kick', state: 'state', verifier: 'pkce', redirectURI: 'multiview://kick'});
    expect(sanitizePendingOAuth({service: 'kick'})).toBeNull();
    expect(sanitizePendingDeviceOAuth({service: 'youtube', deviceCode: 'd'})).toBeNull();
  });

  it('starts Twitch device authorization with chat scopes and a resumable expiry', async () => {
    const fetchMock = jest.fn().mockResolvedValue(response({
      device_code: 'device',
      user_code: 'USER-CODE',
      verification_uri: 'https://www.twitch.tv/activate',
      expires_in: 1800,
      interval: 5,
    }));
    globalThis.fetch = fetchMock as typeof fetch;

    const before = Date.now();
    const code = await requestTwitchDeviceCode(twitchAuth());

    expect(code).toMatchObject({
      service: 'twitch',
      deviceCode: 'device',
      userCode: 'USER-CODE',
      verificationUrl: 'https://www.twitch.tv/activate',
      intervalSeconds: 5,
    });
    expect(code.expiresAt).toBeGreaterThanOrEqual(before + 1_799_000);
    expect(fetchMock).toHaveBeenCalledWith('https://id.twitch.tv/oauth2/device', expect.objectContaining({
      method: 'POST',
      body: expect.stringContaining('scopes=user%3Aread%3Achat%20user%3Awrite%3Achat'),
    }));
  });

  it('keeps polling while Twitch reports authorization_pending', async () => {
    globalThis.fetch = jest.fn().mockResolvedValue(response({status: 400, message: 'authorization_pending'}, false, 400)) as typeof fetch;
    const code: PendingDeviceOAuth = {
      service: 'twitch',
      deviceCode: 'device',
      userCode: 'code',
      verificationUrl: 'https://www.twitch.tv/activate',
      expiresAt: Date.now() + 60_000,
      intervalSeconds: 5,
    };
    await expect(pollTwitchDeviceToken(twitchAuth(), code)).resolves.toBeNull();
  });

  it('classifies device-code slow_down, transient server errors, and terminal OAuth errors', async () => {
    const code: PendingDeviceOAuth = {
      service: 'twitch',
      deviceCode: 'device',
      userCode: 'code',
      verificationUrl: 'https://www.twitch.tv/activate',
      expiresAt: Date.now() + 60_000,
      intervalSeconds: 5,
    };
    globalThis.fetch = jest.fn()
      .mockResolvedValueOnce(response({message: 'slow_down'}, false, 400))
      .mockResolvedValueOnce(response({message: 'temporarily unavailable'}, false, 503))
      .mockResolvedValueOnce(response({message: 'expired_token'}, false, 400)) as typeof fetch;

    const slowDown = await pollTwitchDeviceToken(twitchAuth(), code).catch(error => error);
    const transient = await pollTwitchDeviceToken(twitchAuth(), code).catch(error => error);
    const terminal = await pollTwitchDeviceToken(twitchAuth(), code).catch(error => error);

    expect(deviceOAuthErrorDisposition(slowDown)).toBe('slow_down');
    expect(deviceOAuthErrorDisposition(transient)).toBe('retry');
    expect(deviceOAuthErrorDisposition(terminal)).toBe('terminal');
    expect(nextDeviceOAuthPollInterval(10, 'slow_down')).toBe(15);
    expect(nextDeviceOAuthPollInterval(10, 'retry')).toBe(20);
  });

  it('stores Twitch refresh token and user id after device authorization', async () => {
    const fetchMock = jest.fn()
      .mockResolvedValueOnce(response({
        access_token: 'access-1',
        refresh_token: 'refresh-1',
        expires_in: 14400,
        scope: ['user:read:chat', 'user:write:chat'],
      }))
      .mockResolvedValueOnce(response({user_id: 'user-1'}));
    globalThis.fetch = fetchMock as typeof fetch;
    const code: PendingDeviceOAuth = {
      service: 'twitch',
      deviceCode: 'device',
      userCode: 'code',
      verificationUrl: 'https://www.twitch.tv/activate',
      expiresAt: Date.now() + 60_000,
      intervalSeconds: 5,
    };

    const next = await pollTwitchDeviceToken(twitchAuth(), code);

    expect(next?.twitch.token).toMatchObject({
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      userID: 'user-1',
      scope: 'user:read:chat user:write:chat',
    });
    expect(fetchMock).toHaveBeenNthCalledWith(2, 'https://id.twitch.tv/oauth2/validate', {
      headers: {Authorization: 'OAuth access-1'},
    });
  });

  it('preserves issued Twitch tokens when validation is temporarily unavailable and resolves user id on send', async () => {
    const deviceFetch = jest.fn()
      .mockResolvedValueOnce(response({
        access_token: 'access-1',
        refresh_token: 'refresh-1',
        expires_in: 14400,
      }))
      .mockRejectedValueOnce(new TypeError('network unavailable'));
    globalThis.fetch = deviceFetch as typeof fetch;
    const code: PendingDeviceOAuth = {
      service: 'twitch',
      deviceCode: 'device',
      userCode: 'code',
      verificationUrl: 'https://www.twitch.tv/activate',
      expiresAt: Date.now() + 60_000,
      intervalSeconds: 5,
    };

    const authorized = await pollTwitchDeviceToken(twitchAuth(), code);
    expect(authorized?.twitch.token).toMatchObject({
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      userID: undefined,
    });

    const sendFetch = jest.fn()
      .mockResolvedValueOnce(response({user_id: 'user-1'}))
      .mockResolvedValueOnce(response({data: [{id: 'broadcaster-1'}]}))
      .mockResolvedValueOnce(response({}));
    globalThis.fetch = sendFetch as typeof fetch;
    const onAuthUpdated = jest.fn();
    const stream: StreamItem = {id: 'twitch:test', platform: 'twitch', channel: 'test'};

    const next = await postStreamComment(authorized as AuthState, stream, 'hello', onAuthUpdated);

    expect(next.twitch.token?.userID).toBe('user-1');
    expect(onAuthUpdated).toHaveBeenCalledWith(expect.objectContaining({
      twitch: expect.objectContaining({token: expect.objectContaining({userID: 'user-1'})}),
    }));
    expect(sendFetch).toHaveBeenNthCalledWith(1, 'https://id.twitch.tv/oauth2/validate', {
      headers: {Authorization: 'OAuth access-1'},
    });
  });

  it('rotates an expired Twitch token before posting and returns the refreshed auth state', async () => {
    const fetchMock = jest.fn()
      .mockResolvedValueOnce(response({
        access_token: 'access-2',
        refresh_token: 'refresh-2',
        expires_in: 14400,
        scope: ['user:read:chat', 'user:write:chat'],
      }))
      .mockResolvedValueOnce(response({data: [{id: 'broadcaster-1'}]}))
      .mockResolvedValueOnce(response({}));
    globalThis.fetch = fetchMock as typeof fetch;
    const auth = twitchAuth({
      accessToken: 'expired-access',
      refreshToken: 'refresh-1',
      expiresAt: Date.now() - 1,
      userID: 'user-1',
    });
    const stream: StreamItem = {
      id: 'twitch:test',
      platform: 'twitch',
      channel: 'test',
    };

    const next = await postStreamComment(auth, stream, 'hello');

    expect(next.twitch.token).toMatchObject({accessToken: 'access-2', refreshToken: 'refresh-2', userID: 'user-1'});
    expect(fetchMock).toHaveBeenNthCalledWith(1, 'https://id.twitch.tv/oauth2/token', expect.objectContaining({
      body: expect.stringContaining('refresh_token=refresh-1'),
    }));
    expect(fetchMock).toHaveBeenNthCalledWith(3, 'https://api.twitch.tv/helix/chat/messages', expect.objectContaining({
      headers: expect.objectContaining({Authorization: 'Bearer access-2'}),
    }));
  });

  it('publishes a rotated token even when the following API request fails', async () => {
    const fetchMock = jest.fn()
      .mockResolvedValueOnce(response({
        access_token: 'access-2',
        refresh_token: 'refresh-2',
        expires_in: 14400,
      }))
      .mockResolvedValueOnce(response({message: 'channel lookup failed'}, false, 503));
    globalThis.fetch = fetchMock as typeof fetch;
    const auth = twitchAuth({
      accessToken: 'expired-access',
      refreshToken: 'refresh-1',
      expiresAt: Date.now() - 1,
      userID: 'user-1',
    });
    const stream: StreamItem = {
      id: 'twitch:test',
      platform: 'twitch',
      channel: 'test',
    };
    const onAuthUpdated = jest.fn();

    await expect(postStreamComment(auth, stream, 'hello', onAuthUpdated))
      .rejects.toThrow('channel lookup failed');

    expect(onAuthUpdated).toHaveBeenCalledTimes(1);
    expect(onAuthUpdated.mock.calls[0][0].twitch.token).toMatchObject({
      accessToken: 'access-2',
      refreshToken: 'refresh-2',
      userID: 'user-1',
    });
  });

  it('clears an unusable token after a terminal refresh rejection', async () => {
    globalThis.fetch = jest.fn().mockResolvedValue(response({message: 'invalid refresh token'}, false, 400)) as typeof fetch;
    const auth = twitchAuth({
      accessToken: 'expired-access',
      refreshToken: 'revoked-refresh',
      expiresAt: Date.now() - 1,
      userID: 'user-1',
    });
    const stream: StreamItem = {id: 'twitch:test', platform: 'twitch', channel: 'test'};
    const onAuthUpdated = jest.fn();

    await expect(postStreamComment(auth, stream, 'hello', onAuthUpdated))
      .rejects.toThrow('invalid refresh token');

    expect(onAuthUpdated).toHaveBeenCalledTimes(1);
    expect(onAuthUpdated.mock.calls[0][0].twitch.token).toBeUndefined();
  });
});
