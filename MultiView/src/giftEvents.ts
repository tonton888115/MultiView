import type {ChatEvent, PlatformId} from './types';

export type GiftEventKind = 'superchat' | 'sub' | 'gift' | 'nicoad' | 'notification';

export type GiftEvent = {
  id: string;
  platform: PlatformId;
  author?: string;
  text: string;
  headline: string;
  kind: GiftEventKind;
  createdAt: number;
};

type Listener = (event: GiftEvent) => void;

const listeners = new Map<string, Set<Listener>>();
const pending = new Map<string, GiftEvent[]>();
const seen = new Map<string, Map<string, number>>();
const pendingLifetimeMs = 30_000;
const seenLifetimeMs = 10 * 60_000;
const maxPendingPerStream = 50;

export function subscribeGiftEvents(streamId: string, listener: Listener): () => void {
  const key = streamId.trim();
  let set = listeners.get(key);
  if (!set) {
    set = new Set();
    listeners.set(key, set);
  }
  set.add(listener);
  const queued = pending.get(key) ?? [];
  pending.delete(key);
  const cutoff = Date.now() - pendingLifetimeMs;
  queued.filter(event => event.createdAt >= cutoff).forEach(event => {
    try {
      listener(event);
    } catch {
      // A newly mounted overlay will receive future events even if one replay fails.
    }
  });
  return () => {
    const current = listeners.get(key);
    if (!current) {
      return;
    }
    current.delete(listener);
    if (current.size === 0) {
      listeners.delete(key);
    }
  };
}

export function publishGiftEvent(streamId: string, event: GiftEvent): void {
  const key = streamId.trim();
  const now = Date.now();
  let streamSeen = seen.get(key);
  if (!streamSeen) {
    streamSeen = new Map();
    seen.set(key, streamSeen);
  }
  streamSeen.forEach((timestamp, id) => {
    if (timestamp < now - seenLifetimeMs) {
      streamSeen?.delete(id);
    }
  });
  if (streamSeen.has(event.id)) {
    return;
  }
  streamSeen.set(event.id, now);

  const set = listeners.get(key);
  if (!set?.size) {
    const queued = pending.get(key) ?? [];
    queued.push(event);
    pending.set(key, queued.slice(-maxPendingPerStream));
    return;
  }
  let delivered = false;
  set.forEach(listener => {
    try {
      listener(event);
      delivered = true;
    } catch {
      // listener errors must not break the session
    }
  });
  if (!delivered) {
    const queued = pending.get(key) ?? [];
    queued.push(event);
    pending.set(key, queued.slice(-maxPendingPerStream));
  }
}

export function giftEventFromChatEvent(_streamId: string, event: ChatEvent): GiftEvent | null {
  if (!event.superInfo) {
    return null;
  }
  const giftEvent: GiftEvent = {
    id: event.id,
    platform: event.platform,
    text: event.text,
    headline: event.superInfo,
    kind: giftKindFromSuperInfo(event.platform, event.superInfo),
    createdAt: event.createdAt,
  };
  if (event.author) {
    giftEvent.author = event.author;
  }
  return giftEvent;
}

function giftKindFromSuperInfo(_platform: PlatformId, superInfo: string): GiftEventKind {
  const lower = superInfo.toLowerCase();
  // Keep this intentionally text-based until each platform exposes structured gift metadata.
  if (lower.includes('gift')) {
    return 'gift';
  }
  if (lower.includes('sub') || lower.includes('member')) {
    return 'sub';
  }
  return 'superchat';
}
