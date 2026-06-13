import {desktopUserAgent, mobileUserAgent, resolveLiveYouTubeVideoID, webStreamURL, youtubeVideoId} from './playback';
import {kickFilterText, kickTokens, makeChatEvent, parseTwitchTags, textTokens, twitchTokens} from './danmaku';
import type {AppSettings, ChatEvent, DanmakuToken, PlatformId, StreamItem} from './types';

export type ChatClient = {
  stop: () => void;
};

type Emit = (event: ChatEvent) => void;
type Status = (message: string) => void;
type YouTubeChatSession = {
  apiKey: string;
  context: any;
  continuation: string;
  headerClientName?: string;
  clientVersion?: string;
  visitorData?: string;
};
type YouTubeChatConfig = {
  apiKey?: string;
  headerClientName?: string;
  clientVersion?: string;
  visitorData?: string;
  context?: any;
  continuation?: string;
};

const youtubeChatMinPollMs = 700;
const youtubeChatMaxPollMs = 1600;
const youtubeChatReconnectMs = 3500;
const youtubeChatSeenLimit = 20000;
const youtubeChatSeenKeep = 12000;

export function startChatClient(stream: StreamItem, settings: AppSettings, emit: Emit, status: Status): ChatClient {
  if (!settings.showChat || !settings.showDanmaku) {
    return emptyClient();
  }
  switch (stream.platform) {
    case 'twitch':
      return startTwitchChat(stream, emit, status);
    case 'kick':
      return startKickChat(stream, emit, status);
    case 'youtube':
      return startYouTubeChat(stream, emit, status);
    case 'twitcasting':
      return startTwitCastingChat(stream, emit, status);
    case 'niconico':
      status('ニコ生弾幕はWebフォールバック中');
      return emptyClient();
  }
}

function emptyClient(): ChatClient {
  return {stop: () => undefined};
}

function cleanChannel(raw: string): string {
  return raw.trim().replace(/^@+/, '');
}

function startTwitchChat(stream: StreamItem, emit: Emit, status: Status): ChatClient {
  const channel = cleanChannel(stream.channel).toLowerCase().split(/[/?#]/)[0];
  if (!channel) {
    return emptyClient();
  }
  let stopped = false;
  let socket: WebSocket | undefined;
  let retryTimer: ReturnType<typeof setTimeout> | undefined;
  const connect = () => {
    if (stopped) {
      return;
    }
    status('Twitchコメント接続中');
    socket = new WebSocket('wss://irc-ws.chat.twitch.tv:443');
    socket.onopen = () => {
      const nick = `justinfan${Math.floor(Math.random() * 900000 + 10000)}`;
      socket?.send('CAP REQ :twitch.tv/tags twitch.tv/commands');
      socket?.send('PASS SCHMOOPIIE');
      socket?.send(`NICK ${nick}`);
      socket?.send(`JOIN #${channel}`);
      status('Twitchコメント接続済み');
    };
    socket.onmessage = event => {
      const text = String(event.data ?? '');
      if (text.includes('PING :tmi.twitch.tv')) {
        socket?.send('PONG :tmi.twitch.tv');
      }
      handleTwitchMessage(text, stream.platform, emit);
    };
    socket.onerror = () => {
      status('Twitchコメント再接続待ち');
    };
    socket.onclose = () => {
      if (!stopped) {
        retryTimer = setTimeout(connect, 3000);
      }
    };
  };
  connect();
  return {
    stop: () => {
      stopped = true;
      if (retryTimer) {
        clearTimeout(retryTimer);
      }
      socket?.close();
    },
  };
}

function handleTwitchMessage(text: string, platform: PlatformId, emit: Emit) {
  text.split('\r\n').forEach(rawLine => {
    if (!rawLine) {
      return;
    }
    if (rawLine.startsWith('PING')) {
      return;
    }
    let line = rawLine;
    let tags: Record<string, string> = {};
    if (line.startsWith('@')) {
      const split = line.indexOf(' ');
      if (split > 0) {
        tags = parseTwitchTags(line.slice(1, split));
        line = line.slice(split + 1);
      }
    }
    const isPrivmsg = line.includes(' PRIVMSG ');
    const isUserNotice = line.includes(' USERNOTICE ');
    if (!isPrivmsg && !isUserNotice) {
      return;
    }
    const bodyMarker = line.indexOf(' :');
    const message = bodyMarker >= 0 ? line.slice(bodyMarker + 2) : '';
    const systemMessage = tags['system-msg'] || tags['msg-id'] || '';
    const displayText = message || systemMessage;
    if (!displayText) {
      return;
    }
    const id = tags.id || `${platform}:${Date.now()}:${Math.random()}`;
    const noticeKind = (tags['msg-id'] ?? '').toLowerCase();
    const superInfo = isUserNotice && /sub|gift|raid|ritual/.test(noticeKind) ? systemMessage || noticeKind : undefined;
    emit(makeChatEvent(
      platform,
      id,
      displayText,
      message ? twitchTokens(message, tags.emotes) : textTokens(displayText),
      tags['display-name'] || tags.login,
      superInfo,
    ));
  });
}

function startKickChat(stream: StreamItem, emit: Emit, status: Status): ChatClient {
  let stopped = false;
  let socket: WebSocket | undefined;
  let retryTimer: ReturnType<typeof setTimeout> | undefined;
  const channel = cleanChannel(stream.channel);

  const connect = async () => {
    if (stopped) {
      return;
    }
    try {
      status('Kickコメント情報取得中');
      const info = await fetchKickChannelInfo(channel);
      const channels = [`chatrooms.${info.chatroomId}.v2`];
      if (info.channelId) {
        channels.push(`channel.${info.channelId}`);
      }
      if (stopped) {
        return;
      }
      status('Kickコメント接続中');
      socket = new WebSocket('wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679?protocol=7&client=android-native&version=1.0&flash=false');
      socket.onopen = () => {
        channels.forEach(channelName => {
          socket?.send(JSON.stringify({event: 'pusher:subscribe', data: {auth: '', channel: channelName}}));
        });
        status('Kickコメント接続済み');
      };
      socket.onmessage = event => {
        handleKickMessage(String(event.data ?? ''), emit);
      };
      socket.onclose = () => {
        if (!stopped) {
          retryTimer = setTimeout(connect, 3000);
        }
      };
      socket.onerror = () => {
        status('Kickコメント再接続待ち');
      };
    } catch (error) {
      status(error instanceof Error ? error.message : String(error));
      if (!stopped) {
        retryTimer = setTimeout(connect, 5000);
      }
    }
  };
  connect();
  return {
    stop: () => {
      stopped = true;
      if (retryTimer) {
        clearTimeout(retryTimer);
      }
      socket?.close();
    },
  };
}

async function fetchKickChannelInfo(channel: string): Promise<{chatroomId: string; channelId?: string}> {
  const url = `https://kick.com/api/v2/channels/${encodeURIComponent(channel)}`;
  const response = await fetch(url, {
    headers: {
      Accept: 'application/json, text/plain, */*',
      'User-Agent': mobileUserAgent,
      Referer: `https://kick.com/${channel}`,
      Origin: 'https://kick.com',
    },
  });
  if (!response.ok) {
    throw new Error(`Kickコメント情報取得失敗 HTTP ${response.status}`);
  }
  const json = await response.json();
  const chatroomId = stringValue(json?.chatroom?.id)
    ?? stringValue(json?.chatroom_id)
    ?? stringValue(json?.livestream?.chatroom?.id)
    ?? stringValue(json?.livestream?.chatroom_id);
  if (!chatroomId) {
    throw new Error('Kick chatroom IDを取得できません');
  }
  const channelId = stringValue(json?.id) ?? stringValue(json?.livestream?.channel_id);
  return {chatroomId, channelId: channelId ?? undefined};
}

function handleKickMessage(text: string, emit: Emit) {
  const envelope = parseJSON(text);
  const eventName = stringValue(envelope?.event) ?? '';
  if (eventName === 'pusher:ping') {
    return;
  }
  if (!eventName.includes('ChatMessage')) {
    return;
  }
  const payload = typeof envelope?.data === 'string' ? parseJSON(envelope.data) : envelope?.data;
  const content = stringValue(payload?.content) ?? stringValue(payload?.message);
  if (!content) {
    return;
  }
  const sender = payload?.sender ?? payload?.user;
  const author = stringValue(sender?.username) ?? stringValue(sender?.name) ?? stringValue(payload?.username);
  const id = stringValue(payload?.id) ?? `kick:${Date.now()}:${Math.random()}`;
  emit(makeChatEvent('kick', id, kickFilterText(content), kickTokens(content), author ?? undefined));
}

function startYouTubeChat(stream: StreamItem, emit: Emit, status: Status): ChatClient {
  let stopped = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const seen = new Set<string>();
  const videoId = youtubeVideoId(stream.channel);

  const run = async () => {
    try {
      status('YouTubeチャット初期化中');
      const session = await withTimeout(
        createYouTubeChatSession(videoId ?? stream.channel),
        15000,
        'YouTubeチャット初期化タイムアウト',
      );
      let continuation = session.continuation;
      status('YouTubeコメント接続済み');
      const poll = async () => {
        if (stopped) {
          return;
        }
        try {
          const page = await fetchYouTubeChatPage(session, continuation);
          continuation = page.continuation ?? continuation;
          page.events.forEach(event => {
            if (!seen.has(event.id)) {
              seen.add(event.id);
              emit(event);
            }
          });
          if (seen.size > youtubeChatSeenLimit) {
            const keep = Array.from(seen).slice(-youtubeChatSeenKeep);
            seen.clear();
            keep.forEach(id => seen.add(id));
          }
          timer = setTimeout(poll, page.timeoutMs);
        } catch {
          status('YouTubeコメント再接続中');
          timer = setTimeout(run, youtubeChatReconnectMs);
        }
      };
      poll();
    } catch {
      status('YouTubeライブチャット待機中');
      if (!stopped) {
        timer = setTimeout(run, 5000);
      }
    }
  };
  run();
  return {
    stop: () => {
      stopped = true;
      if (timer) {
        clearTimeout(timer);
      }
    },
  };
}

async function createYouTubeChatSession(raw: string): Promise<YouTubeChatSession> {
  const video = youtubeVideoId(raw)
    ?? youtubeVideoId(webStreamURL({id: 'youtube:tmp', platform: 'youtube', channel: raw}))
    ?? await resolveLiveYouTubeVideoID(raw);
  const targets = youtubeInitialChatTargets(video, raw);
  const htmlDocuments: string[] = [];
  let lastError: unknown;
  for (const target of targets) {
    try {
      htmlDocuments.push(await fetchYouTubeHTML(target.url, target.referer));
      const session = extractYouTubeChatSessionFromHTML(htmlDocuments);
      if (session.apiKey && session.continuation) {
        return session;
      }
    } catch (error) {
      lastError = error;
    }
  }
  try {
    return extractYouTubeChatSessionFromHTML(htmlDocuments);
  } catch (error) {
    throw error ?? lastError;
  }
}

function youtubeInitialChatTargets(video: string | null, raw: string): Array<{url: string; referer?: string}> {
  const fallback = video ? `https://www.youtube.com/watch?v=${encodeURIComponent(video)}` : webStreamURL({id: 'youtube:tmp', platform: 'youtube', channel: raw});
  if (!video) {
    return [{url: fallback}];
  }
  const watch = `https://www.youtube.com/watch?v=${encodeURIComponent(video)}`;
  return [
    {url: `https://www.youtube.com/live_chat?v=${encodeURIComponent(video)}&is_popout=1`, referer: watch},
    {url: watch},
  ];
}

async function fetchYouTubeHTML(url: string, referer?: string): Promise<string> {
  const response = await fetchWithTimeout(url, {
    headers: {
      'User-Agent': desktopUserAgent,
      'Accept-Language': 'ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6',
      ...(referer ? {Referer: referer} : {}),
    },
  }, 10000);
  if (!response.ok) {
    throw new Error(`YouTubeチャット初期HTML取得失敗 HTTP ${response.status}`);
  }
  return response.text();
}

export function extractYouTubeChatSessionFromHTML(htmlDocuments: string[]): YouTubeChatSession {
  const configs = htmlDocuments.map(extractYouTubeChatConfig);
  const apiKey = firstDefined(configs.map(config => config.apiKey));
  if (!apiKey) {
    throw new Error('YouTubeチャットAPIキーを取得できません');
  }
  const context = firstDefined(configs.map(config => config.context));
  const clientVersion = firstDefined(configs.map(config => config.clientVersion))
    ?? context?.client?.clientVersion
    ?? '2.20240620.01.00';
  const visitorData = firstDefined(configs.map(config => config.visitorData))
    ?? stringValue(context?.client?.visitorData)
    ?? undefined;
  const continuation = firstDefined(configs.map(config => config.continuation));
  if (!continuation) {
    throw new Error('YouTubeライブチャットのcontinuationを取得できません');
  }
  return {
    apiKey,
    continuation,
    headerClientName: firstDefined(configs.map(config => config.headerClientName)),
    clientVersion,
    visitorData,
    context: normalizeYouTubeContext(context, clientVersion, visitorData),
  };
}

function extractYouTubeChatConfig(html: string): YouTubeChatConfig {
  const ytcfg = extractYtcfgObject(html);
  const initialData = extractAssignedJSON(html, 'ytInitialData');
  return {
    apiKey: regexGroup(html, /"INNERTUBE_API_KEY"\s*:\s*"([^"]+)"/)
      ?? regexGroup(html, /INNERTUBE_API_KEY['"]?\s*[:=]\s*['"]([^'"]+)/)
      ?? stringValue(ytcfg?.INNERTUBE_API_KEY)
      ?? undefined,
    clientVersion: regexGroup(html, /"INNERTUBE_CLIENT_VERSION"\s*:\s*"([^"]+)"/)
      ?? stringValue(ytcfg?.INNERTUBE_CLIENT_VERSION)
      ?? stringValue(ytcfg?.INNERTUBE_CONTEXT?.client?.clientVersion)
      ?? undefined,
    headerClientName: regexGroup(html, /"INNERTUBE_CONTEXT_CLIENT_NAME"\s*:\s*"?(\d+)"?/)
      ?? stringValue(ytcfg?.INNERTUBE_CONTEXT_CLIENT_NAME)
      ?? undefined,
    visitorData: stringValue(ytcfg?.VISITOR_DATA)
      ?? stringValue(ytcfg?.INNERTUBE_CONTEXT?.client?.visitorData)
      ?? undefined,
    context: ytcfg?.INNERTUBE_CONTEXT,
    continuation: (initialData ? findLiveChatContinuation(initialData) : null)
      ?? findLiveChatContinuation(ytcfg)
      ?? regexGroup(html, /"continuation"\s*:\s*"([^"]+)"/)
      ?? undefined,
  };
}

function normalizeYouTubeContext(context: any, clientVersion: string, visitorData?: string): any {
  return {
    ...(context ?? {}),
    client: {
      ...(context?.client ?? {}),
      clientName: context?.client?.clientName ?? 'WEB',
      clientVersion,
      hl: context?.client?.hl ?? 'ja',
      gl: context?.client?.gl ?? 'JP',
      userAgent: context?.client?.userAgent ?? desktopUserAgent,
      ...(visitorData ? {visitorData} : {}),
    },
  };
}

async function fetchYouTubeChatPage(session: YouTubeChatSession, continuation: string): Promise<{events: ChatEvent[]; continuation?: string; timeoutMs: number}> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    'User-Agent': desktopUserAgent,
    'Accept-Language': 'ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.6',
  };
  if (session.headerClientName) {
    headers['X-YouTube-Client-Name'] = session.headerClientName;
  }
  if (session.clientVersion) {
    headers['X-YouTube-Client-Version'] = session.clientVersion;
  }
  if (session.visitorData) {
    headers['X-Goog-Visitor-Id'] = session.visitorData;
  }
  const response = await fetchWithTimeout(`https://www.youtube.com/youtubei/v1/live_chat/get_live_chat?key=${encodeURIComponent(session.apiKey)}`, {
    method: 'POST',
    headers,
    body: JSON.stringify({context: session.context, continuation}),
  }, 10000);
  if (!response.ok) {
    throw new Error('YouTubeコメント再接続中');
  }
  const json = await response.json();
  const live = json?.continuationContents?.liveChatContinuation;
  const events = youtubeChatEventsFromAction(json);
  const next = continuationFromList(live?.continuations) ?? findLiveChatContinuation(json) ?? continuation;
  const timeoutMs = youtubeChatPollDelayMs(timeoutFromContinuations(live?.continuations));
  return {events, continuation: next, timeoutMs};
}

export function youtubeChatPollDelayMs(serverTimeoutMs?: number): number {
  const requested = Number.isFinite(serverTimeoutMs) && serverTimeoutMs != null
    ? serverTimeoutMs
    : youtubeChatMaxPollMs;
  return Math.min(youtubeChatMaxPollMs, Math.max(youtubeChatMinPollMs, requested));
}

export function youtubeChatEventsFromAction(action: any): ChatEvent[] {
  const rendererKeys = [
    'liveChatTextMessageRenderer',
    'liveChatPaidMessageRenderer',
    'liveChatPaidStickerRenderer',
    'liveChatMembershipItemRenderer',
    'liveChatSponsorshipsGiftPurchaseAnnouncementRenderer',
    'liveChatSponsorshipsGiftRedemptionAnnouncementRenderer',
    'liveChatGiftMembershipReceivedRenderer',
    'liveChatViewerEngagementMessageRenderer',
    'liveChatModeChangeMessageRenderer',
    'liveChatPlaceholderItemRenderer',
    'liveChatAutoModMessageRenderer',
    'liveChatBannerRenderer',
    'liveChatBannerHeaderRenderer',
    'liveChatTickerPaidMessageItemRenderer',
    'liveChatTickerSponsorItemRenderer',
    'liveChatDonationAnnouncementRenderer',
    'liveChatPollRenderer',
  ];
  const renderers: any[] = [];
  const walk = (value: any) => {
    if (!value) {
      return;
    }
    if (Array.isArray(value)) {
      value.forEach(walk);
      return;
    }
    if (typeof value !== 'object') {
      return;
    }
    rendererKeys.forEach(key => {
      if (value[key]) {
        renderers.push(value[key]);
      }
    });
    Object.values(value).forEach(walk);
  };
  walk(action);
  const seen = new Set<string>();
  return renderers
    .map((renderer: any) => youtubeRendererToEvent(renderer))
    .filter((event): event is ChatEvent => {
      if (!event || seen.has(event.id)) {
        return false;
      }
      seen.add(event.id);
      return true;
    });
}

function youtubeRendererToEvent(renderer: any): ChatEvent | null {
  const id = stringValue(renderer.id) ?? `youtube:${Date.now()}:${Math.random()}`;
  const author = runsText(renderer.authorName?.runs) || stringValue(renderer.authorName?.simpleText);
  const stickerLabel = stringValue(renderer.sticker?.accessibility?.accessibilityData?.label)
    ?? stringValue(renderer.sticker?.accessibility?.label)
    ?? stringValue(renderer.sticker?.label);
  const stickerImage = bestThumbnail(renderer.sticker?.thumbnails ?? renderer.sticker?.image?.thumbnails);
  const tokens: DanmakuToken[] = [];
  if (stickerImage) {
    tokens.push({kind: 'image', url: stickerImage, alt: stickerLabel ?? 'sticker'});
  }
  const textObjects = [
    renderer.message,
    renderer.headerPrimaryText,
    renderer.headerSubtext,
    renderer.primaryText,
    renderer.subtext,
    renderer.bodyText,
    renderer.text,
  ];
  textObjects.forEach(value => {
    tokens.push(...youtubeTextObjectToTokens(value));
  });
  if (tokens.length === 0 && stickerLabel) {
    tokens.push({kind: 'text', text: stickerLabel});
  }
  const text = tokensText(tokens);
  const superInfo = youtubeTextObjectText(renderer.purchaseAmountText)
    ?? youtubeTextObjectText(renderer.headerPrimaryText)
    ?? (renderer.liveChatSponsorshipsHeaderRenderer ? 'メンバー加入' : undefined);
  if (!text.trim() && !superInfo) {
    return null;
  }
  return makeChatEvent('youtube', id, text || superInfo || '', tokens.length ? tokens : textTokens(superInfo ?? ''), author ?? undefined, superInfo);
}

function youtubeTextObjectToTokens(value: any): DanmakuToken[] {
  if (!value) {
    return [];
  }
  if (Array.isArray(value?.runs)) {
    return youtubeRunsToTokens(value.runs);
  }
  const simpleText = stringValue(value?.simpleText) ?? stringValue(value);
  return simpleText ? textTokens(simpleText) : [];
}

function youtubeTextObjectText(value: any): string | undefined {
  if (!value) {
    return undefined;
  }
  const fromRuns = runsText(value?.runs);
  return fromRuns || stringValue(value?.simpleText) || stringValue(value) || undefined;
}

function youtubeRunsToTokens(runs: any[]): DanmakuToken[] {
  const tokens: DanmakuToken[] = [];
  runs.forEach(run => {
    if (typeof run?.text === 'string') {
      tokens.push({kind: 'text', text: run.text});
      return;
    }
    const emoji = run?.emoji;
    const url = bestThumbnail(emoji?.image?.thumbnails);
    if (url) {
      tokens.push({
        kind: 'image',
        url,
        alt: stringValue(emoji?.shortcuts?.[0])
          ?? stringValue(emoji?.emojiId)
          ?? stringValue(emoji?.searchTerms?.[0])
          ?? 'emoji',
      });
    }
  });
  return tokens;
}

function startTwitCastingChat(stream: StreamItem, emit: Emit, status: Status): ChatClient {
  let stopped = false;
  let socket: WebSocket | undefined;
  let retryTimer: ReturnType<typeof setTimeout> | undefined;
  const channel = cleanChannel(stream.channel);
  const connect = async () => {
    try {
      status('ツイキャスコメント接続中');
      const movieId = await fetchTwitCastingMovieId(channel);
      const wsURL = await fetchTwitCastingSubscribeURL(movieId, channel);
      if (stopped) {
        return;
      }
      socket = new WebSocket(wsURL);
      socket.onopen = () => status('ツイキャスコメント接続済み');
      socket.onmessage = event => handleTwitCastingMessage(String(event.data ?? ''), emit);
      socket.onclose = () => {
        if (!stopped) {
          retryTimer = setTimeout(connect, 5000);
        }
      };
    } catch (error) {
      status(error instanceof Error ? error.message : String(error));
      if (!stopped) {
        retryTimer = setTimeout(connect, 5000);
      }
    }
  };
  connect();
  return {
    stop: () => {
      stopped = true;
      if (retryTimer) {
        clearTimeout(retryTimer);
      }
      socket?.close();
    },
  };
}

async function fetchTwitCastingMovieId(channel: string): Promise<string> {
  const response = await fetch(`https://frontendapi.twitcasting.tv/users/${encodeURIComponent(channel)}/latest-movie`, {
    headers: {
      Accept: 'application/json',
      'User-Agent': mobileUserAgent,
      Referer: `https://twitcasting.tv/${channel}`,
    },
  });
  const json = await response.json();
  const id = stringValue(json?.movie?.id);
  if (!id) {
    throw new Error('ツイキャス配信IDを取得できません');
  }
  return id;
}

async function fetchTwitCastingSubscribeURL(movieId: string, channel: string): Promise<string> {
  const response = await fetch('https://twitcasting.tv/eventpubsuburl.php', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Accept: 'application/json, text/javascript, */*; q=0.01',
      'User-Agent': mobileUserAgent,
      Referer: `https://twitcasting.tv/${channel}`,
      Origin: 'https://twitcasting.tv',
      'X-Requested-With': 'XMLHttpRequest',
    },
    body: `movie_id=${encodeURIComponent(movieId)}`,
  });
  const json = await response.json();
  const url = stringValue(json?.url);
  if (!url) {
    throw new Error('ツイキャスコメントURLを取得できません');
  }
  return url;
}

function handleTwitCastingMessage(text: string, emit: Emit) {
  const json = parseJSON(text);
  walkCommentItems(json).forEach(item => {
    const message = stringValue(item.message);
    if (message) {
      const author = stringValue(item.author?.name) ?? stringValue(item.user?.name) ?? undefined;
      emit(makeChatEvent('twitcasting', stringValue(item.id) ?? `twitcasting:${Date.now()}:${Math.random()}`, message, textTokens(message), author));
    }
  });
}

function walkCommentItems(value: any): any[] {
  if (Array.isArray(value)) {
    return value.flatMap(walkCommentItems);
  }
  if (!value || typeof value !== 'object') {
    return [];
  }
  const type = stringValue(value.type) ?? stringValue(value.event) ?? '';
  if (stringValue(value.message) && (!type || type.toLowerCase().includes('comment') || value.author || value.user)) {
    return [value];
  }
  return ['message', 'data', 'payload'].flatMap(key => walkCommentItems(value[key]));
}

function findLiveChatContinuation(root: any): string | null {
  const allMessagesContinuation = findAllMessagesLiveChatContinuation(root);
  if (allMessagesContinuation) {
    return allMessagesContinuation;
  }
  const direct = root?.contents?.twoColumnWatchNextResults?.conversationBar?.liveChatRenderer?.continuations;
  const fromDirect = continuationFromList(direct);
  if (fromDirect) {
    return fromDirect;
  }
  let found: string | null = null;
  const walk = (value: any) => {
    if (found || !value) {
      return;
    }
    if (Array.isArray(value)) {
      value.forEach(walk);
      return;
    }
    if (typeof value !== 'object') {
      return;
    }
    if (value.liveChatRenderer?.continuations) {
      found = continuationFromList(value.liveChatRenderer.continuations) ?? null;
      return;
    }
    if (value.liveChatContinuation?.continuations) {
      found = continuationFromList(value.liveChatContinuation.continuations) ?? null;
      return;
    }
    Object.values(value).forEach(walk);
  };
  walk(root);
  return found;
}

function findAllMessagesLiveChatContinuation(root: any): string | null {
  let found: string | null = null;
  const walk = (value: any) => {
    if (found || !value) {
      return;
    }
    if (Array.isArray(value)) {
      value.forEach(walk);
      return;
    }
    if (typeof value !== 'object') {
      return;
    }
    const menu = value.sortFilterSubMenuRenderer;
    const items = Array.isArray(menu?.subMenuItems) ? menu.subMenuItems : [];
    for (const item of items) {
      const title = youtubeTextObjectText(item?.title) ?? '';
      const subtitle = youtubeTextObjectText(item?.subtitle) ?? '';
      const label = stringValue(item?.accessibility?.accessibilityData?.label) ?? '';
      const haystack = `${title} ${subtitle} ${label}`.toLowerCase();
      const isTopChat = haystack.includes('top chat') || haystack.includes('トップチャット');
      const isAllMessages = haystack.includes('live chat')
        || haystack.includes('all messages')
        || haystack.includes('すべてのメッセージ')
        || (haystack.includes('チャット') && !isTopChat);
      if (!isTopChat && isAllMessages) {
        found = continuationFromData(item?.continuation) ?? continuationFromData(item?.serviceEndpoint) ?? null;
        if (found) {
          return;
        }
      }
    }
    Object.values(value).forEach(walk);
  };
  walk(root);
  return found;
}

function continuationFromData(value: any): string | undefined {
  for (const key of ['timedContinuationData', 'invalidationContinuationData', 'reloadContinuationData', 'liveChatReplayContinuationData']) {
    const continuation = value?.[key]?.continuation;
    if (typeof continuation === 'string' && continuation) {
      return continuation;
    }
  }
  const commandToken = value?.continuationCommand?.token;
  if (typeof commandToken === 'string' && commandToken) {
    return commandToken;
  }
  return undefined;
}

function continuationFromList(list: any): string | undefined {
  if (!Array.isArray(list)) {
    return undefined;
  }
  for (const item of list) {
    const value = continuationFromData(item);
    if (typeof value === 'string' && value) {
      return value;
    }
  }
  return undefined;
}

function timeoutFromContinuations(list: any): number | undefined {
  if (!Array.isArray(list)) {
    return undefined;
  }
  for (const item of list) {
    const value = item?.timedContinuationData?.timeoutMs ?? item?.invalidationContinuationData?.timeoutMs;
    if (value != null) {
      return Number(value);
    }
  }
  return undefined;
}

function extractAssignedJSON(html: string, name: string): any | null {
  const markers = [`var ${name} = `, `window["${name}"] = `, `${name} = `];
  for (const marker of markers) {
    const index = html.indexOf(marker);
    if (index < 0) {
      continue;
    }
    const start = html.indexOf('{', index + marker.length);
    if (start < 0) {
      continue;
    }
    const json = balancedObject(html, start);
    if (json) {
      return parseJSON(json);
    }
  }
  return null;
}

function extractYtcfgObject(html: string): any | null {
  const marker = 'ytcfg.set(';
  let cursor = 0;
  let found = false;
  const merged: any = {};
  while (cursor < html.length) {
    const index = html.indexOf(marker, cursor);
    if (index < 0) {
      break;
    }
    const start = html.indexOf('{', index + marker.length);
    if (start < 0) {
      break;
    }
    const json = balancedObject(html, start);
    const object = json ? parseJSON(json) : null;
    if (object && typeof object === 'object' && !Array.isArray(object)) {
      Object.assign(merged, object);
      found = true;
    }
    cursor = start + 1;
  }
  return found ? merged : null;
}

function balancedObject(text: string, start: number): string | null {
  let depth = 0;
  let inString = false;
  let escape = false;
  for (let index = start; index < text.length; index += 1) {
    const char = text[index];
    if (inString) {
      if (escape) {
        escape = false;
      } else if (char === '\\') {
        escape = true;
      } else if (char === '"') {
        inString = false;
      }
      continue;
    }
    if (char === '"') {
      inString = true;
    } else if (char === '{') {
      depth += 1;
    } else if (char === '}') {
      depth -= 1;
      if (depth === 0) {
        return text.slice(start, index + 1);
      }
    }
  }
  return null;
}

function regexGroup(text: string, pattern: RegExp): string | null {
  return text.match(pattern)?.[1] ?? null;
}

function firstDefined<T>(values: Array<T | null | undefined>): T | undefined {
  return values.find((value): value is T => value != null);
}

function runsText(runs: any): string {
  return Array.isArray(runs) ? runs.map((run: any) => stringValue(run?.text) ?? '').join('') : '';
}

function tokensText(tokens: DanmakuToken[]): string {
  return tokens.map(token => (token.kind === 'text' ? token.text : token.alt ?? '')).join('');
}

function bestThumbnail(thumbnails: any): string | null {
  if (!Array.isArray(thumbnails) || thumbnails.length === 0) {
    return null;
  }
  const sorted = thumbnails
    .filter(item => typeof item?.url === 'string')
    .sort((a, b) => Number(b.width ?? 0) - Number(a.width ?? 0));
  const url = sorted[0]?.url;
  return typeof url === 'string' && url.startsWith('//') ? `https:${url}` : url ?? null;
}

function parseJSON(text: string): any | null {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

async function fetchWithTimeout(url: string, init: RequestInit, timeoutMs: number): Promise<Response> {
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<Response>((_, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new Error(`Request timed out after ${timeoutMs}ms`));
    }, timeoutMs);
  });
  try {
    return await Promise.race([fetch(url, {...init, signal: controller.signal}), timeout]);
  } finally {
    if (timer) {
      clearTimeout(timer);
    }
  }
}

async function withTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<T>((_, reject) => {
    timer = setTimeout(() => reject(new Error(message)), timeoutMs);
  });
  try {
    return await Promise.race([promise, timeout]);
  } finally {
    if (timer) {
      clearTimeout(timer);
    }
  }
}

function stringValue(value: unknown): string | null {
  if (typeof value === 'string' && value.trim()) {
    return value;
  }
  if (typeof value === 'number') {
    return String(value);
  }
  return null;
}
