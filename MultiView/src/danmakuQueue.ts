import type {AppSettings, ChatEvent} from './types';

const duplicateWindowMs = 10000;

export type RecentDanmakuEvents = Map<string, number>;

export class DanmakuEventQueue {
  private items: ChatEvent[] = [];
  private head = 0;

  get length(): number {
    return this.items.length - this.head;
  }

  peek(): ChatEvent | undefined {
    return this.items[this.head];
  }

  append(event: ChatEvent): void {
    this.items.push(event);
  }

  consume(): ChatEvent | undefined {
    if (this.head >= this.items.length) {
      return undefined;
    }
    const event = this.items[this.head];
    this.head += 1;
    // Amortized O(1): compact only after enough consumed storage accumulates.
    if (this.head >= 1024 && this.head * 2 >= this.items.length) {
      this.items = this.items.slice(this.head);
      this.head = 0;
    }
    return event;
  }

  removeWhere(predicate: (event: ChatEvent) => boolean): void {
    const kept = this.items.slice(this.head).filter(event => !predicate(event));
    this.items = kept;
    this.head = 0;
  }

  clear(): void {
    this.items = [];
    this.head = 0;
  }
}

export function isDanmakuEnabled(settings: Pick<AppSettings, 'showDanmaku'>): boolean {
  return settings.showDanmaku;
}

/**
 * Suppress only the same platform message ID. Repeated visible text is common in
 * busy chats (and especially for emoji), so text fingerprints must not discard
 * distinct messages from the official surface.
 */
export function isRecentDanmakuDuplicate(
  event: ChatEvent,
  recent: RecentDanmakuEvents,
  now = Date.now(),
): boolean {
  for (const [key, timestamp] of recent) {
    if (now - timestamp > duplicateWindowMs) {
      recent.delete(key);
    }
  }
  const key = eventIdentity(event);
  if (recent.has(key)) {
    return true;
  }
  recent.set(key, now);
  return false;
}

export function eventIdentity(event: ChatEvent): string {
  const id = event.platform === 'youtube' && event.id.startsWith('yt-dom:')
    ? event.id.slice('yt-dom:'.length)
    : event.id;
  return `${event.platform}\u001f${id}`;
}

/** Append without dropping older received comments during a high-flow burst. */
export function appendDanmakuEvent(queue: DanmakuEventQueue, event: ChatEvent): void {
  queue.append(event);
}

export function consumeDanmakuEvent(queue: DanmakuEventQueue): ChatEvent | undefined {
  return queue.consume();
}
