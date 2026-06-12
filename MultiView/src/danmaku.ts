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
      return sum + Math.max(18, fontSize * 1.4) + 6;
    }
    return sum + estimateTextWidth(token.text, fontSize);
  }, 12);
}

function estimateTextWidth(text: string, fontSize: number): number {
  let units = 0;
  for (const char of Array.from(text)) {
    const code = char.codePointAt(0) ?? 0;
    if (/\s/.test(char)) {
      units += 0.35;
    } else if (isWideGlyph(code)) {
      units += 1;
    } else {
      units += 0.58;
    }
  }
  return units * fontSize;
}

function isWideGlyph(code: number): boolean {
  return (
    (code >= 0x1100 && code <= 0x11ff) ||
    (code >= 0x2e80 && code <= 0xa4cf) ||
    (code >= 0xac00 && code <= 0xd7a3) ||
    (code >= 0xf900 && code <= 0xfaff) ||
    (code >= 0xfe10 && code <= 0xfe6f) ||
    (code >= 0xff00 && code <= 0xffef) ||
    (code >= 0x1f000 && code <= 0x1faff)
  );
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
