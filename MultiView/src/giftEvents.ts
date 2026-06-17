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

export function subscribeGiftEvents(streamId: string, listener: Listener): () => void {
  const key = streamId.trim();
  let set = listeners.get(key);
  if (!set) {
    set = new Set();
    listeners.set(key, set);
  }
  set.add(listener);
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
  const set = listeners.get(streamId.trim());
  if (!set) {
    return;
  }
  set.forEach(listener => {
    try {
      listener(event);
    } catch {
      // listener errors must not break the session
    }
  });
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
