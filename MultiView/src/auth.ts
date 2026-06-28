import {Linking} from 'react-native';
import {cleanChannel, desktopUserAgent, mobileUserAgent, youtubeVideoId} from './playback';
import type {StreamItem} from './types';

export const AUTH_STORAGE_KEY = 'multiview.android.auth.v1';
export const PENDING_OAUTH_STORAGE_KEY = 'multiview.android.pending-oauth.v1';
export const PENDING_DEVICE_OAUTH_STORAGE_KEY = 'multiview.android.pending-device-oauth.v1';

export type OAuthService = 'kick' | 'twitch' | 'twitcasting' | 'youtube';

export type OAuthToken = {
  accessToken: string;
  refreshToken?: string;
  expiresAt: number;
  userID?: string;
  scope?: string;
};

export type ServiceAuthConfig = {
  clientId: string;
  clientSecret?: string;
  redirectURI: string;
};

export type ServiceAuthState = {
  config: ServiceAuthConfig;
  token?: OAuthToken;
};

export type AuthState = Record<OAuthService, ServiceAuthState>;

export type PendingOAuth = {
  service: Exclude<OAuthService, 'youtube'> | 'youtube';
  state: string;
  verifier?: string;
  redirectURI: string;
};

export type OAuthStart = {
  pending: PendingOAuth;
  url: string;
};

export type YouTubeDeviceCode = {
  deviceCode: string;
  userCode: string;
  verificationUrl: string;
  expiresAt: number;
  intervalSeconds: number;
};

export type OAuthURLSingleFlight = {
  run: (url: string, task: () => Promise<void>) => Promise<boolean>;
};

export type DeviceOAuthErrorDisposition = 'retry' | 'slow_down' | 'terminal';

type TaggedOAuthError = Error & {
  deviceOAuthDisposition?: DeviceOAuthErrorDisposition;
  terminalOAuthFailure?: boolean;
};

export type PendingDeviceOAuth = YouTubeDeviceCode & {
  service: 'twitch' | 'youtube';
};

const twitchRedirect = 'https://tonton888115.github.io/MultiView/twitch-oauth.html';
const kickRedirect = 'https://tonton888115.github.io/MultiView/kick-oauth.html';
const twitcastingRedirect = 'multiview://twitcasting-oauth';
const youtubeRedirect = 'multiview://youtube-oauth';
const twitchChatScopes = 'user:read:chat user:write:chat';
const authRefreshLeadMs = 5 * 60_000;
const twitchValidationIntervalMs = 60 * 60_000;
const refreshFlights = new Map<OAuthService, Promise<OAuthToken>>();
let lastTwitchValidationAt = 0;

const browserHeaders = {
  Accept: 'application/json, text/plain, */*',
  'Accept-Language': 'ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7',
  'User-Agent': mobileUserAgent,
};

export const defaultAuthState: AuthState = {
  kick: {config: {clientId: '', clientSecret: '', redirectURI: kickRedirect}},
  twitch: {config: {clientId: '', redirectURI: twitchRedirect}},
  twitcasting: {config: {clientId: '', redirectURI: twitcastingRedirect}},
  youtube: {config: {clientId: '', redirectURI: youtubeRedirect}},
};

export function sanitizeAuthState(raw: unknown): AuthState {
  const source = typeof raw === 'object' && raw ? (raw as Partial<AuthState>) : {};
  return {
    kick: sanitizeService(source.kick, defaultAuthState.kick),
    twitch: sanitizeService(source.twitch, defaultAuthState.twitch),
    twitcasting: sanitizeService(source.twitcasting, defaultAuthState.twitcasting),
    youtube: sanitizeService(source.youtube, defaultAuthState.youtube),
  };
}

export function sanitizePendingOAuth(raw: unknown): PendingOAuth | null {
  if (!raw || typeof raw !== 'object') {
    return null;
  }
  const value = raw as Partial<PendingOAuth>;
  if (!['kick', 'twitch', 'twitcasting', 'youtube'].includes(String(value.service))
    || typeof value.state !== 'string' || !value.state
    || typeof value.redirectURI !== 'string' || !value.redirectURI) {
    return null;
  }
  return {
    service: value.service as PendingOAuth['service'],
    state: value.state,
    redirectURI: value.redirectURI,
    verifier: typeof value.verifier === 'string' && value.verifier ? value.verifier : undefined,
  };
}

export function sanitizePendingDeviceOAuth(raw: unknown): PendingDeviceOAuth | null {
  if (!raw || typeof raw !== 'object') {
    return null;
  }
  const value = raw as Partial<PendingDeviceOAuth>;
  const service = value.service === 'twitch' || value.service === 'youtube' ? value.service : null;
  const expiresAt = finiteNumber(value.expiresAt);
  const intervalSeconds = finiteNumber(value.intervalSeconds);
  if (!service
    || typeof value.deviceCode !== 'string' || !value.deviceCode
    || typeof value.userCode !== 'string' || !value.userCode
    || typeof value.verificationUrl !== 'string' || !value.verificationUrl
    || expiresAt == null || intervalSeconds == null || intervalSeconds < 1) {
    return null;
  }
  return {
    service,
    deviceCode: value.deviceCode,
    userCode: value.userCode,
    verificationUrl: value.verificationUrl,
    expiresAt,
    intervalSeconds,
  };
}

export function authStatus(auth: AuthState, service: OAuthService): string {
  const token = auth[service].token;
  if (!token) {
    return '未ログイン';
  }
  if (token.expiresAt > Date.now()) {
    if (service === 'twitch' && !token.refreshToken) {
      return 'ログイン済み（再ログインで自動更新を有効化）';
    }
    return 'ログイン済み';
  }
  return token.refreshToken ? 'ログイン済み（自動更新）' : '期限切れ';
}

export function hasUsableAuthSession(auth: AuthState, service: OAuthService): boolean {
  const token = auth[service].token;
  return !!token && (token.expiresAt > Date.now() || !!token.refreshToken);
}

export function createOAuthURLSingleFlight(): OAuthURLSingleFlight {
  let processingURL: string | null = null;
  return {
    async run(url, task) {
      if (processingURL) {
        return false;
      }
      processingURL = url;
      try {
        await task();
        return true;
      } finally {
        processingURL = null;
      }
    },
  };
}

export function deviceOAuthErrorDisposition(error: unknown): DeviceOAuthErrorDisposition {
  if (error instanceof Error) {
    return (error as TaggedOAuthError).deviceOAuthDisposition ?? 'retry';
  }
  return 'retry';
}

export function oauthCompletionErrorDisposition(error: unknown): 'retry' | 'terminal' {
  return isTerminalOAuthFailure(error) ? 'terminal' : 'retry';
}

export function nextDeviceOAuthPollInterval(
  currentIntervalSeconds: number,
  disposition: Exclude<DeviceOAuthErrorDisposition, 'terminal'>,
): number {
  const current = positiveNumber(currentIntervalSeconds, 5);
  if (disposition === 'slow_down') {
    return current + 5;
  }
  return Math.max(current, Math.min(60, current * 2));
}

export function isOAuthRedirectForPending(pending: PendingOAuth, rawUrl: string): boolean {
  try {
    const actual = new URL(rawUrl);
    if (actual.protocol !== 'multiview:') {
      return false;
    }
    const expected = new URL(pending.redirectURI);
    if (expected.protocol === 'multiview:') {
      return actual.hostname === expected.hostname && normalizedPath(actual.pathname) === normalizedPath(expected.pathname);
    }
    // Kick/Twitch first land on an HTTPS bridge page which forwards to this
    // canonical custom-scheme callback. The provider redirect itself therefore
    // cannot be compared byte-for-byte with the URL delivered to the app.
    return actual.hostname === `${pending.service}-oauth` && normalizedPath(actual.pathname) === '/';
  } catch {
    return false;
  }
}

export function serviceLabel(service: OAuthService): string {
  switch (service) {
    case 'kick':
      return 'Kick';
    case 'twitch':
      return 'Twitch';
    case 'twitcasting':
      return 'ツイキャス';
    case 'youtube':
      return 'YouTube';
  }
}

export function updateAuthConfig(auth: AuthState, service: OAuthService, patch: Partial<ServiceAuthConfig>): AuthState {
  return {
    ...auth,
    [service]: {
      ...auth[service],
      config: {...auth[service].config, ...patch},
    },
  };
}

export function signOut(auth: AuthState, service: OAuthService): AuthState {
  return {
    ...auth,
    [service]: {
      ...auth[service],
      token: undefined,
    },
  };
}

export async function createOAuthStart(auth: AuthState, service: Exclude<OAuthService, 'youtube'>): Promise<OAuthStart> {
  const config = auth[service].config;
  const clientId = config.clientId.trim();
  if (!clientId) {
    throw new Error(`${serviceLabel(service)} Client IDが未設定です`);
  }
  const redirectURI = config.redirectURI.trim() || defaultAuthState[service].config.redirectURI;
  const state = randomString(32);
  if (service === 'twitch') {
    const params = new URLSearchParams({
      client_id: clientId,
      redirect_uri: redirectURI,
      response_type: 'token',
      scope: 'user:read:chat user:write:chat',
      state,
    });
    return {pending: {service, state, redirectURI}, url: `https://id.twitch.tv/oauth2/authorize?${params.toString()}`};
  }
  if (service === 'twitcasting') {
    const params = new URLSearchParams({
      client_id: clientId,
      redirect_uri: redirectURI,
      response_type: 'token',
      state,
    });
    return {pending: {service, state, redirectURI}, url: `https://apiv2.twitcasting.tv/oauth2/authorize?${params.toString()}`};
  }
  const verifier = randomVerifier();
  const params = new URLSearchParams({
    response_type: 'code',
    client_id: clientId,
    redirect_uri: redirectURI,
    scope: 'user:read channel:read chat:write',
    state,
    code_challenge: base64UrlFromBytes(sha256(verifier)),
    code_challenge_method: 'S256',
  });
  return {pending: {service, state, verifier, redirectURI}, url: `https://id.kick.com/oauth/authorize?${params.toString()}`};
}

export async function completeOAuthRedirect(auth: AuthState, pending: PendingOAuth, rawUrl: string): Promise<AuthState> {
  const values = callbackValues(rawUrl);
  if (values.state !== pending.state) {
    throw taggedTerminalOAuthError('OAuth stateが一致しません');
  }
  if (pending.service === 'twitch') {
    const accessToken = values.access_token;
    if (!accessToken) {
      throw taggedTerminalOAuthError('Twitch access tokenを取得できません');
    }
    const userID = await validateTwitch(accessToken);
    return saveToken(auth, 'twitch', {
      accessToken,
      userID,
      expiresAt: expiryFromNow(values.expires_in, 3600),
      scope: values.scope,
    });
  }
  if (pending.service === 'twitcasting') {
    const accessToken = values.access_token;
    if (!accessToken) {
      throw taggedTerminalOAuthError('ツイキャス access tokenを取得できません');
    }
    return saveToken(auth, 'twitcasting', {
      accessToken,
      // TwitCasting implicit tokens are valid for 15,552,000 seconds (180 days)
      // and the provider does not issue refresh tokens to public mobile clients.
      expiresAt: expiryFromNow(values.expires_in, 15_552_000),
      scope: values.scope,
    });
  }
  const code = values.code;
  if (!code || !pending.verifier) {
    throw taggedTerminalOAuthError('Kick認証コードを取得できません');
  }
  const token = await exchangeKickCode(auth.kick.config, code, pending.verifier, pending.redirectURI);
  return saveToken(auth, 'kick', token);
}

export async function requestYouTubeDeviceCode(auth: AuthState): Promise<YouTubeDeviceCode> {
  const clientId = auth.youtube.config.clientId.trim();
  if (!clientId) {
    throw new Error('YouTube Client IDが未設定です');
  }
  const response = await fetch('https://oauth2.googleapis.com/device/code', {
    method: 'POST',
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: formBody({
      client_id: clientId,
      scope: 'https://www.googleapis.com/auth/youtube.force-ssl',
    }),
  });
  const json = await response.json();
  if (!response.ok || !json.device_code || !json.user_code) {
    throw new Error(errorDescription(json, `YouTube device code取得失敗 HTTP ${response.status}`));
  }
  return {
    deviceCode: json.device_code,
    userCode: json.user_code,
    verificationUrl: json.verification_url ?? json.verification_uri ?? 'https://www.google.com/device',
    expiresAt: Date.now() + Number(json.expires_in ?? 900) * 1000,
    intervalSeconds: Math.max(3, Number(json.interval ?? 5)),
  };
}

export function mergeAuthMaintenanceSnapshot(
  base: AuthState,
  current: AuthState,
  maintained: AuthState,
): AuthState {
  let merged = current;
  (['kick', 'twitch', 'twitcasting', 'youtube'] as OAuthService[]).forEach(service => {
    const baseValue = JSON.stringify(base[service]);
    if (JSON.stringify(maintained[service]) === baseValue
      || JSON.stringify(current[service]) !== baseValue) {
      return;
    }
    merged = {...merged, [service]: maintained[service]};
  });
  return merged;
}

export async function requestTwitchDeviceCode(auth: AuthState): Promise<PendingDeviceOAuth> {
  const clientId = auth.twitch.config.clientId.trim();
  if (!clientId) {
    throw new Error('Twitch Client IDが未設定です');
  }
  const response = await fetch('https://id.twitch.tv/oauth2/device', {
    method: 'POST',
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: formBody({client_id: clientId, scopes: twitchChatScopes}),
  });
  const json = await response.json().catch(() => ({}));
  if (!response.ok || !json.device_code || !json.user_code || !json.verification_uri) {
    throw new Error(errorDescription(json, `Twitch device code取得失敗 HTTP ${response.status}`));
  }
  return {
    service: 'twitch',
    deviceCode: String(json.device_code),
    userCode: String(json.user_code),
    verificationUrl: String(json.verification_uri),
    expiresAt: expiryFromNow(json.expires_in, 1800, 0),
    intervalSeconds: positiveNumber(json.interval, 5),
  };
}

export async function pollYouTubeDeviceToken(auth: AuthState, code: YouTubeDeviceCode): Promise<AuthState | null> {
  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: formBody({
      client_id: auth.youtube.config.clientId.trim(),
      device_code: code.deviceCode,
      grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
    }),
  });
  const json = await response.json();
  if (!response.ok) {
    if (json.error === 'authorization_pending') {
      return null;
    }
    if (json.error === 'slow_down') {
      throw taggedDeviceOAuthError(errorDescription(json, 'YouTubeから認証確認間隔を延ばすよう要求されました'), 'slow_down');
    }
    throw taggedDeviceOAuthError(
      errorDescription(json, `YouTube token取得失敗 HTTP ${response.status}`),
      retryableHTTPStatus(response.status) ? 'retry' : 'terminal',
    );
  }
  if (!json.access_token) {
    throw new Error('YouTube access tokenを取得できません');
  }
  return saveToken(auth, 'youtube', {
    accessToken: json.access_token,
    refreshToken: json.refresh_token,
    expiresAt: expiryFromNow(json.expires_in, 3600),
    scope: normalizeScope(json.scope),
  });
}

export async function pollTwitchDeviceToken(auth: AuthState, code: PendingDeviceOAuth): Promise<AuthState | null> {
  const response = await fetch('https://id.twitch.tv/oauth2/token', {
    method: 'POST',
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: formBody({
      client_id: auth.twitch.config.clientId.trim(),
      scopes: twitchChatScopes,
      device_code: code.deviceCode,
      grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
    }),
  });
  const json = await response.json().catch(() => ({}));
  if (!response.ok) {
    const pending = String(json.error ?? json.message ?? '').toLowerCase().replace(/\s+/g, '_');
    if (pending.includes('authorization_pending')) {
      return null;
    }
    if (pending.includes('slow_down')) {
      throw taggedDeviceOAuthError(errorDescription(json, 'Twitchから認証確認間隔を延ばすよう要求されました'), 'slow_down');
    }
    throw taggedDeviceOAuthError(
      errorDescription(json, `Twitch token取得失敗 HTTP ${response.status}`),
      retryableHTTPStatus(response.status) ? 'retry' : 'terminal',
    );
  }
  if (!json.access_token || !json.refresh_token) {
    throw new Error('Twitch access token / refresh tokenを取得できません');
  }
  const accessToken = String(json.access_token);
  let userID: string | undefined;
  try {
    userID = await validateTwitch(accessToken);
  } catch (error) {
    // The device code has already been redeemed at this point. Preserve the
    // issued tokens across a transient validate outage and resolve userID on
    // the first send instead of forcing the whole login flow to restart.
    if (oauthCompletionErrorDisposition(error) === 'terminal') {
      throw error;
    }
  }
  return saveToken(auth, 'twitch', {
    accessToken,
    refreshToken: String(json.refresh_token),
    userID,
    expiresAt: expiryFromNow(json.expires_in, 4 * 3600),
    scope: normalizeScope(json.scope),
  });
}

export async function postStreamComment(
  auth: AuthState,
  stream: StreamItem,
  text: string,
  onAuthUpdated?: (nextAuth: AuthState) => void | Promise<void>,
): Promise<AuthState> {
  const content = text.trim();
  if (!content) {
    return auth;
  }
  switch (stream.platform) {
    case 'kick':
      return postKick(auth, stream.channel, content, onAuthUpdated);
    case 'twitch':
      return postTwitch(auth, stream.channel, content, onAuthUpdated);
    case 'youtube':
      return postYouTube(auth, stream.channel, content, onAuthUpdated);
    case 'twitcasting':
      return postTwitcasting(auth, stream.channel, content, onAuthUpdated);
    case 'niconico':
      throw new Error('Androidのニコ生コメント送信はWebログイン画面の送信を使ってください');
  }
}

export function openURL(url: string) {
  return Linking.openURL(url);
}

export async function maintainAuthSessions(
  auth: AuthState,
  onAuthUpdated?: (nextAuth: AuthState) => void | Promise<void>,
): Promise<AuthState> {
  let current = auth;
  const twitch = current.twitch.token;
  if (twitch && Date.now() - lastTwitchValidationAt >= twitchValidationIntervalMs) {
    lastTwitchValidationAt = Date.now();
    try {
      const validation = await validateTwitchSession(twitch.accessToken);
      const expiresAt = validation.expiresInSeconds == null
        ? twitch.expiresAt
        : Date.now() + Math.max(60, validation.expiresInSeconds - 60) * 1000;
      if (validation.userID !== twitch.userID || expiresAt !== twitch.expiresAt) {
        current = saveToken(current, 'twitch', {...twitch, userID: validation.userID, expiresAt});
        await onAuthUpdated?.(current);
      }
    } catch (error) {
      if (isTerminalOAuthFailure(error)) {
        if (twitch.refreshToken) {
          try {
            const refreshed = await authorizedToken(current, 'twitch', onAuthUpdated, Number.POSITIVE_INFINITY);
            current = refreshed.auth;
          } catch (refreshError) {
            if (isTerminalOAuthFailure(refreshError)) {
              current = signOut(current, 'twitch');
              await onAuthUpdated?.(current);
            }
          }
        } else {
          current = signOut(current, 'twitch');
          await onAuthUpdated?.(current);
        }
      }
    }
  }

  for (const service of ['kick', 'twitch', 'youtube'] as OAuthService[]) {
    const token = current[service].token;
    if (!token?.refreshToken || token.expiresAt > Date.now() + authRefreshLeadMs) {
      continue;
    }
    try {
      const refreshed = await authorizedToken(current, service, onAuthUpdated, authRefreshLeadMs);
      current = refreshed.auth;
    } catch (error) {
      if (isTerminalOAuthFailure(error)) {
        current = signOut(current, service);
      }
    }
  }
  return current;
}

async function postKick(
  auth: AuthState,
  channel: string,
  content: string,
  onAuthUpdated?: (nextAuth: AuthState) => void | Promise<void>,
): Promise<AuthState> {
  const {auth: nextAuth, token} = await authorizedToken(auth, 'kick', onAuthUpdated);
  const slug = serviceChannelSlug(channel);
  const lookup = await fetch(`https://api.kick.com/public/v1/channels?slug=${encodeURIComponent(slug)}`, {
    headers: {...browserHeaders, Authorization: `Bearer ${token.accessToken}`},
  });
  const lookupJson = await lookup.json().catch(() => ({}));
  const row = lookupJson?.data?.[0];
  const broadcasterID = numberValue(row?.broadcaster_user_id ?? row?.user_id);
  if (!lookup.ok || broadcasterID == null) {
    throw new Error(errorDescription(lookupJson, `KickチャンネルIDを取得できません HTTP ${lookup.status}`));
  }
  const response = await fetch('https://api.kick.com/public/v1/chat', {
    method: 'POST',
    headers: {...browserHeaders, Authorization: `Bearer ${token.accessToken}`, 'Content-Type': 'application/json'},
    body: JSON.stringify({broadcaster_user_id: broadcasterID, content: content.slice(0, 500), type: 'user'}),
  });
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new Error(errorDescription(body, `Kickコメント送信に失敗しました HTTP ${response.status}`));
  }
  return nextAuth;
}

async function postTwitch(
  auth: AuthState,
  channel: string,
  content: string,
  onAuthUpdated?: (nextAuth: AuthState) => void | Promise<void>,
): Promise<AuthState> {
  let {auth: nextAuth, token} = await authorizedToken(auth, 'twitch', onAuthUpdated);
  let senderID = token.userID;
  if (!senderID) {
    senderID = await validateTwitch(token.accessToken);
    token = {...token, userID: senderID};
    nextAuth = saveToken(nextAuth, 'twitch', token);
    await onAuthUpdated?.(nextAuth);
  }
  const login = serviceChannelSlug(channel);
  const response = await fetch(`https://api.twitch.tv/helix/users?login=${encodeURIComponent(login)}`, {
    headers: {
      Authorization: `Bearer ${token.accessToken}`,
      'Client-Id': auth.twitch.config.clientId.trim(),
    },
  });
  const json = await response.json().catch(() => ({}));
  const broadcasterID = json?.data?.[0]?.id;
  if (!response.ok || !broadcasterID) {
    throw new Error(errorDescription(json, `TwitchチャンネルIDを取得できません HTTP ${response.status}`));
  }
  const send = await fetch('https://api.twitch.tv/helix/chat/messages', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token.accessToken}`,
      'Client-Id': auth.twitch.config.clientId.trim(),
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({broadcaster_id: broadcasterID, sender_id: senderID, message: content}),
  });
  if (!send.ok) {
    const body = await send.text().catch(() => '');
    throw new Error(body.trim() || `Twitchコメント送信に失敗しました HTTP ${send.status}`);
  }
  return nextAuth;
}

async function postTwitcasting(
  auth: AuthState,
  channel: string,
  content: string,
  onAuthUpdated?: (nextAuth: AuthState) => void | Promise<void>,
): Promise<AuthState> {
  const {auth: nextAuth, token} = await authorizedToken(auth, 'twitcasting', onAuthUpdated);
  const user = serviceChannelSlug(channel);
  const latest = await fetch(`https://frontendapi.twitcasting.tv/users/${encodeURIComponent(user)}/latest-movie`, {
    headers: {Accept: 'application/json', 'User-Agent': mobileUserAgent},
  });
  const latestJson = await latest.json().catch(() => ({}));
  const movieID = stringValue(latestJson?.movie?.id);
  if (!latest.ok || !movieID) {
    throw new Error(errorDescription(latestJson, `ツイキャス配信IDを取得できません HTTP ${latest.status}`));
  }
  const send = await fetch(`https://apiv2.twitcasting.tv/movies/${encodeURIComponent(movieID)}/comments`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token.accessToken}`,
      'X-Api-Version': '2.0',
      Accept: 'application/json',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({comment: content.slice(0, 140), sns: 'none'}),
  });
  if (!send.ok) {
    const body = await send.text().catch(() => '');
    throw new Error(body.trim() || `ツイキャスコメント送信に失敗しました HTTP ${send.status}`);
  }
  return nextAuth;
}

async function postYouTube(
  auth: AuthState,
  channel: string,
  content: string,
  onAuthUpdated?: (nextAuth: AuthState) => void | Promise<void>,
): Promise<AuthState> {
  const {auth: nextAuth, token} = await authorizedToken(auth, 'youtube', onAuthUpdated);
  const videoID = youtubeVideoId(channel) ?? (await resolveYouTubeVideoID(channel));
  if (!videoID) {
    throw new Error('YouTubeライブ動画IDを取得できません');
  }
  const details = await fetch(`https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=${encodeURIComponent(videoID)}`, {
    headers: {Authorization: `Bearer ${token.accessToken}`},
  });
  const detailsJson = await details.json().catch(() => ({}));
  const liveChatID = detailsJson?.items?.[0]?.liveStreamingDetails?.activeLiveChatId;
  if (!details.ok || !liveChatID) {
    throw new Error(errorDescription(detailsJson, `YouTubeライブチャットIDを取得できません HTTP ${details.status}`));
  }
  const send = await fetch('https://www.googleapis.com/youtube/v3/liveChat/messages?part=snippet', {
    method: 'POST',
    headers: {Authorization: `Bearer ${token.accessToken}`, 'Content-Type': 'application/json'},
    body: JSON.stringify({
      snippet: {
        liveChatId: liveChatID,
        type: 'textMessageEvent',
        textMessageDetails: {messageText: content},
      },
    }),
  });
  if (!send.ok) {
    const body = await send.text().catch(() => '');
    throw new Error(body.trim() || `YouTubeコメント送信に失敗しました HTTP ${send.status}`);
  }
  return nextAuth;
}

async function authorizedToken(
  auth: AuthState,
  service: OAuthService,
  onAuthUpdated?: (nextAuth: AuthState) => void | Promise<void>,
  minimumValidityMs = 60_000,
): Promise<{auth: AuthState; token: OAuthToken}> {
  const token = auth[service].token;
  if (!token) {
    throw new Error(`${serviceLabel(service)}にログインしてください`);
  }
  if (token.expiresAt > Date.now() + minimumValidityMs) {
    return {auth, token};
  }
  if (!token.refreshToken) {
    throw new Error(`${serviceLabel(service)}ログインの期限が切れました。再ログインしてください`);
  }
  try {
    const next = await refreshTokenSingleFlight(auth, service, token);
    const nextAuth = saveToken(auth, service, next);
    await onAuthUpdated?.(nextAuth);
    return {auth: nextAuth, token: next};
  } catch (error) {
    if (isTerminalOAuthFailure(error)) {
      await onAuthUpdated?.(signOut(auth, service));
    }
    throw error;
  }
}

function refreshTokenSingleFlight(auth: AuthState, service: OAuthService, token: OAuthToken): Promise<OAuthToken> {
  const active = refreshFlights.get(service);
  if (active) {
    return active;
  }
  const refreshToken = token.refreshToken;
  if (!refreshToken) {
    return Promise.reject(new Error(`${serviceLabel(service)} refresh tokenがありません`));
  }
  let flight: Promise<OAuthToken>;
  if (service === 'kick') {
    flight = refreshKickToken(auth.kick.config, refreshToken);
  } else if (service === 'twitch') {
    flight = refreshTwitchToken(auth.twitch.config, token);
  } else if (service === 'youtube') {
    flight = refreshYouTubeToken(auth.youtube.config, refreshToken);
  } else {
    flight = Promise.reject(new Error('ツイキャスはrefresh tokenを提供していません'));
  }
  refreshFlights.set(service, flight);
  flight.finally(() => {
    if (refreshFlights.get(service) === flight) {
      refreshFlights.delete(service);
    }
  }).catch(() => undefined);
  return flight;
}

async function validateTwitch(accessToken: string): Promise<string> {
  return (await validateTwitchSession(accessToken)).userID;
}

async function validateTwitchSession(accessToken: string): Promise<{userID: string; expiresInSeconds?: number}> {
  const response = await fetch('https://id.twitch.tv/oauth2/validate', {
    headers: {Authorization: `OAuth ${accessToken}`},
  });
  const json = await response.json().catch(() => ({}));
  if (!response.ok || !json.user_id) {
    throw taggedRefreshError(errorDescription(json, 'TwitchユーザーIDを取得できません'), response.status);
  }
  const expiresIn = Number(json.expires_in);
  return {
    userID: json.user_id,
    expiresInSeconds: Number.isFinite(expiresIn) && expiresIn > 0 ? expiresIn : undefined,
  };
}

async function exchangeKickCode(config: ServiceAuthConfig, code: string, verifier: string, redirectURI: string): Promise<OAuthToken> {
  const values: Record<string, string> = {
    grant_type: 'authorization_code',
    client_id: config.clientId.trim(),
    redirect_uri: redirectURI,
    code,
    code_verifier: verifier,
  };
  const secret = config.clientSecret?.trim();
  if (secret) {
    values.client_secret = secret;
  }
  return kickTokenRequest(config, values);
}

async function refreshKickToken(config: ServiceAuthConfig, refreshToken: string): Promise<OAuthToken> {
  const values: Record<string, string> = {
    grant_type: 'refresh_token',
    client_id: config.clientId.trim(),
    refresh_token: refreshToken,
  };
  const secret = config.clientSecret?.trim();
  if (secret) {
    values.client_secret = secret;
  }
  return kickTokenRequest(config, values, refreshToken);
}

async function kickTokenRequest(config: ServiceAuthConfig, values: Record<string, string>, previousRefreshToken?: string): Promise<OAuthToken> {
  const response = await fetch('https://id.kick.com/oauth/token', {
    method: 'POST',
    headers: {...browserHeaders, Origin: 'https://kick.com', Referer: 'https://kick.com/', 'Content-Type': 'application/x-www-form-urlencoded'},
    body: formBody(values),
  });
  const json = await response.json().catch(() => ({}));
  if (!response.ok || !json.access_token) {
    throw taggedRefreshError(errorDescription(json, `Kick token取得失敗 HTTP ${response.status}`), response.status);
  }
  return {
    accessToken: json.access_token,
    refreshToken: json.refresh_token ?? previousRefreshToken,
    expiresAt: expiryFromNow(json.expires_in, 3600),
    scope: normalizeScope(json.scope),
  };
}

async function refreshTwitchToken(config: ServiceAuthConfig, previous: OAuthToken): Promise<OAuthToken> {
  const response = await fetch('https://id.twitch.tv/oauth2/token', {
    method: 'POST',
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: formBody({
      client_id: config.clientId.trim(),
      grant_type: 'refresh_token',
      refresh_token: previous.refreshToken ?? '',
    }),
  });
  const json = await response.json().catch(() => ({}));
  if (!response.ok || !json.access_token || !json.refresh_token) {
    throw taggedRefreshError(errorDescription(json, `Twitch token更新失敗 HTTP ${response.status}`), response.status);
  }
  return {
    accessToken: String(json.access_token),
    refreshToken: String(json.refresh_token),
    userID: previous.userID,
    expiresAt: expiryFromNow(json.expires_in, 4 * 3600),
    scope: normalizeScope(json.scope) ?? previous.scope,
  };
}

async function refreshYouTubeToken(config: ServiceAuthConfig, refreshToken: string): Promise<OAuthToken> {
  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: formBody({
      client_id: config.clientId.trim(),
      grant_type: 'refresh_token',
      refresh_token: refreshToken,
    }),
  });
  const json = await response.json().catch(() => ({}));
  if (!response.ok || !json.access_token) {
    throw taggedRefreshError(errorDescription(json, `YouTube token更新失敗 HTTP ${response.status}`), response.status);
  }
  return {
    accessToken: json.access_token,
    refreshToken: json.refresh_token ?? refreshToken,
    expiresAt: expiryFromNow(json.expires_in, 3600),
    scope: normalizeScope(json.scope),
  };
}

async function resolveYouTubeVideoID(raw: string): Promise<string | null> {
  const trimmed = raw.trim();
  const target = trimmed.includes('youtube.com') || trimmed.includes('youtu.be')
    ? trimmed
    : `https://www.youtube.com/${trimmed.startsWith('@') ? trimmed : `@${trimmed}`}/live`;
  const response = await fetch(target, {
    headers: {'User-Agent': desktopUserAgent, 'Accept-Language': 'ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6'},
  });
  const finalID = youtubeVideoId(response.url);
  if (finalID) {
    return finalID;
  }
  const html = await response.text();
  return html.match(/"videoId"\s*:\s*"([A-Za-z0-9_-]{11})"/)?.[1]
    ?? html.match(/watch\?v=([A-Za-z0-9_-]{11})/)?.[1]
    ?? null;
}

function sanitizeService(raw: ServiceAuthState | undefined, fallback: ServiceAuthState): ServiceAuthState {
  const config: Partial<ServiceAuthConfig> = raw?.config ?? {};
  const token = sanitizeToken(raw?.token);
  return {
    config: {
      clientId: typeof config.clientId === 'string' ? config.clientId : fallback.config.clientId,
      clientSecret: typeof config.clientSecret === 'string' ? config.clientSecret : fallback.config.clientSecret,
      redirectURI: typeof config.redirectURI === 'string' && config.redirectURI.trim() ? config.redirectURI : fallback.config.redirectURI,
    },
    token,
  };
}

function sanitizeToken(raw: OAuthToken | undefined): OAuthToken | undefined {
  if (!raw || typeof raw.accessToken !== 'string' || !raw.accessToken) {
    return undefined;
  }
  return {
    accessToken: raw.accessToken,
    refreshToken: typeof raw.refreshToken === 'string' && raw.refreshToken ? raw.refreshToken : undefined,
    expiresAt: finiteNumber(raw.expiresAt) ?? 0,
    userID: typeof raw.userID === 'string' && raw.userID ? raw.userID : undefined,
    scope: normalizeScope(raw.scope),
  };
}

function saveToken(auth: AuthState, service: OAuthService, token: OAuthToken): AuthState {
  return {
    ...auth,
    [service]: {
      ...auth[service],
      token,
    },
  };
}

function callbackValues(rawUrl: string): Record<string, string> {
  const output: Record<string, string> = {};
  const url = new URL(rawUrl);
  url.searchParams.forEach((value, key) => {
    output[key] = value;
  });
  if (url.hash.startsWith('#')) {
    new URLSearchParams(url.hash.slice(1)).forEach((value, key) => {
      output[key] = value;
    });
  }
  return output;
}

function formBody(values: Record<string, string>): string {
  return Object.entries(values)
    .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`)
    .join('&');
}

function randomString(length: number): string {
  const alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  return Array.from({length}, () => alphabet[Math.floor(Math.random() * alphabet.length)]).join('');
}

function randomVerifier(): string {
  const alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
  return Array.from({length: 64}, () => alphabet[Math.floor(Math.random() * alphabet.length)]).join('');
}

function errorDescription(json: any, fallback: string): string {
  return stringValue(json?.error_description)
    ?? stringValue(json?.message)
    ?? stringValue(json?.error?.message)
    ?? fallback;
}

function stringValue(value: unknown): string | undefined {
  if (typeof value === 'string' && value.trim()) {
    return value;
  }
  if (typeof value === 'number') {
    return String(value);
  }
  return undefined;
}

function numberValue(value: unknown): number | undefined {
  if (typeof value === 'number') {
    return value;
  }
  if (typeof value === 'string' && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  return undefined;
}

function finiteNumber(value: unknown): number | undefined {
  const parsed = typeof value === 'number' ? value : typeof value === 'string' && value.trim() ? Number(value) : NaN;
  return Number.isFinite(parsed) ? parsed : undefined;
}

function positiveNumber(value: unknown, fallback: number): number {
  const parsed = finiteNumber(value);
  return parsed != null && parsed > 0 ? parsed : fallback;
}

function normalizedPath(pathname: string): string {
  const normalized = pathname.replace(/\/+$/, '');
  return normalized || '/';
}

function retryableHTTPStatus(status: number): boolean {
  return status === 408 || status === 425 || status === 429 || status >= 500;
}

function taggedDeviceOAuthError(message: string, disposition: DeviceOAuthErrorDisposition): Error {
  const error = new Error(message) as TaggedOAuthError;
  error.deviceOAuthDisposition = disposition;
  return error;
}

function taggedRefreshError(message: string, status: number): Error {
  const error = new Error(message) as TaggedOAuthError;
  error.terminalOAuthFailure = status >= 400 && status < 500 && !retryableHTTPStatus(status);
  return error;
}

function taggedTerminalOAuthError(message: string): Error {
  const error = new Error(message) as TaggedOAuthError;
  error.terminalOAuthFailure = true;
  return error;
}

function isTerminalOAuthFailure(error: unknown): boolean {
  return error instanceof Error && (error as TaggedOAuthError).terminalOAuthFailure === true;
}

function expiryFromNow(value: unknown, fallbackSeconds: number, skewSeconds = 60): number {
  const seconds = positiveNumber(value, fallbackSeconds);
  return Date.now() + Math.max(60, seconds - skewSeconds) * 1000;
}

function normalizeScope(value: unknown): string | undefined {
  if (Array.isArray(value)) {
    const scope = value.filter(item => typeof item === 'string' && item).join(' ');
    return scope || undefined;
  }
  return typeof value === 'string' && value.trim() ? value : undefined;
}

function serviceChannelSlug(raw: string): string {
  return cleanChannel(raw)
    .trim()
    .replace(/^@+/, '')
    .toLowerCase()
    .split(/[/?#\s]/)[0];
}

// Small SHA-256 implementation for OAuth PKCE. React Native/Hermes does not expose
// WebCrypto consistently, and adding a native crypto dependency just for PKCE is
// heavier than this isolated function.
/* eslint-disable no-bitwise, no-div-regex */
function sha256(input: string): number[] {
  const bytes = utf8Bytes(input);
  const bitLength = bytes.length * 8;
  bytes.push(0x80);
  while ((bytes.length % 64) !== 56) {
    bytes.push(0);
  }
  for (let i = 7; i >= 0; i -= 1) {
    bytes.push((bitLength / (2 ** (i * 8))) & 0xff);
  }
  const h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  const k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  const w = new Array<number>(64);
  for (let offset = 0; offset < bytes.length; offset += 64) {
    for (let i = 0; i < 16; i += 1) {
      const j = offset + i * 4;
      w[i] = ((bytes[j] << 24) | (bytes[j + 1] << 16) | (bytes[j + 2] << 8) | bytes[j + 3]) >>> 0;
    }
    for (let i = 16; i < 64; i += 1) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, hh] = h;
    for (let i = 0; i < 64; i += 1) {
      const s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const temp1 = (hh + s1 + ch + k[i] + w[i]) >>> 0;
      const s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (s0 + maj) >>> 0;
      hh = g;
      g = f;
      f = e;
      e = (d + temp1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) >>> 0;
    }
    h[0] = (h[0] + a) >>> 0;
    h[1] = (h[1] + b) >>> 0;
    h[2] = (h[2] + c) >>> 0;
    h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0;
    h[5] = (h[5] + f) >>> 0;
    h[6] = (h[6] + g) >>> 0;
    h[7] = (h[7] + hh) >>> 0;
  }
  return h.flatMap(value => [(value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff]);
}

function utf8Bytes(input: string): number[] {
  const encoded = encodeURIComponent(input);
  const bytes: number[] = [];
  for (let i = 0; i < encoded.length; i += 1) {
    if (encoded[i] === '%') {
      bytes.push(parseInt(encoded.slice(i + 1, i + 3), 16));
      i += 2;
    } else {
      bytes.push(encoded.charCodeAt(i));
    }
  }
  return bytes;
}

function rotr(value: number, bits: number): number {
  return (value >>> bits) | (value << (32 - bits));
}

function base64UrlFromBytes(bytes: number[]): string {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let output = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i];
    const b = bytes[i + 1] ?? 0;
    const c = bytes[i + 2] ?? 0;
    const triplet = (a << 16) | (b << 8) | c;
    output += alphabet[(triplet >>> 18) & 63];
    output += alphabet[(triplet >>> 12) & 63];
    output += i + 1 < bytes.length ? alphabet[(triplet >>> 6) & 63] : '=';
    output += i + 2 < bytes.length ? alphabet[triplet & 63] : '=';
  }
  return output.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}
/* eslint-enable no-bitwise, no-div-regex */
