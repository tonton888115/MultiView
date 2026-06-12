import type {ChatEvent, DanmakuToken, PlatformId} from './types';

export function textTokens(text: string): DanmakuToken[] {
  return [{kind: 'text', text}];
}

export function makeChatEvent(
  platform: PlatformId,
  id: string,
  text: string,
  tokens: DanmakuToken[] = textTokens(text),
  author?: string,
  superInfo?: string,
): ChatEvent {
  return {
    id,
    platform,
    author,
    text,
    tokens: tokens.length ? tokens : textTokens(text),
    superInfo,
    highlighted: !!superInfo,
    createdAt: Date.now(),
  };
}

export function twitchTokens(message: string, emotesTag?: string): DanmakuToken[] {
  const chars = Array.from(message);
  const ranges: Array<{id: string; start: number; end: number}> = [];
  emotesTag?.split('/').forEach(part => {
    const [id, rawRanges] = part.split(':');
    if (!id || !rawRanges) {
      return;
    }
    rawRanges.split(',').forEach(rawRange => {
      const [startRaw, endRaw] = rawRange.split('-');
      const start = Number(startRaw);
      const end = Number(endRaw);
      if (Number.isInteger(start) && Number.isInteger(end) && start >= 0 && end >= start && end < chars.length) {
        ranges.push({id, start, end});
      }
    });
  });
  ranges.sort((a, b) => a.start - b.start);

  const tokens: DanmakuToken[] = [];
  let cursor = 0;
  for (const range of ranges) {
    if (range.start < cursor) {
      continue;
    }
    if (cursor < range.start) {
      tokens.push({kind: 'text', text: chars.slice(cursor, range.start).join('')});
    }
    tokens.push({
      kind: 'image',
      url: `https://static-cdn.jtvnw.net/emoticons/v2/${encodeURIComponent(range.id)}/animated/dark/2.0`,
      alt: chars.slice(range.start, range.end + 1).join(''),
    });
    cursor = range.end + 1;
  }
  if (cursor < chars.length) {
    tokens.push({kind: 'text', text: chars.slice(cursor).join('')});
  }
  return tokens.length ? tokens : textTokens(message);
}

export function parseTwitchTags(raw: string): Record<string, string> {
  const tags: Record<string, string> = {};
  raw.split(';').forEach(pair => {
    const eq = pair.indexOf('=');
    if (eq <= 0) {
      return;
    }
    tags[pair.slice(0, eq)] = pair
      .slice(eq + 1)
      .replace(/\\s/g, ' ')
      .replace(/\\:/g, ';')
      .replace(/\\r/g, '\r')
      .replace(/\\n/g, '\n');
  });
  return tags;
}

export function kickTokens(content: string): DanmakuToken[] {
  const tokens: DanmakuToken[] = [];
  const pattern = /\[emote:(\d+):([^\]]+)\]/g;
  let cursor = 0;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(content))) {
    if (match.index > cursor) {
      tokens.push({kind: 'text', text: content.slice(cursor, match.index)});
    }
    tokens.push({
      kind: 'image',
      url: `https://files.kick.com/emotes/${encodeURIComponent(match[1])}/fullsize`,
      alt: match[2],
    });
    cursor = match.index + match[0].length;
  }
  if (cursor < content.length) {
    tokens.push({kind: 'text', text: content.slice(cursor)});
  }
  return tokens.length ? tokens : textTokens(content);
}

export function kickFilterText(content: string): string {
  return content.replace(/\[emote:\d+:([^\]]+)\]/g, '$1');
}

export function estimateTokenWidth(tokens: DanmakuToken[], fontSize: number): number {
  return tokens.reduce((sum, token) => {
    if (token.kind === 'image') {
      return sum + Math.max(22, fontSize * 1.5);
    }
    return sum + Array.from(token.text).length * fontSize * 0.72;
  }, 12);
}

export function textFromTokens(tokens: DanmakuToken[]): string {
  return tokens
    .map(token => {
      if (token.kind === 'image') {
        return token.alt ?? '';
      }
      return token.text;
    })
    .join('');
}
