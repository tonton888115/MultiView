import {
  appendDanmakuEvent,
  consumeDanmakuEvent,
  DanmakuEventQueue,
  isDanmakuEnabled,
  isRecentDanmakuDuplicate,
} from '../danmakuQueue';
import {makeChatEvent, textTokens} from '../danmaku';

describe('danmaku queue', () => {
  it('keeps danmaku enabled when only the expanded-chat panel is disabled', () => {
    expect(isDanmakuEnabled({showDanmaku: true})).toBe(true);
    expect(isDanmakuEnabled({showDanmaku: false})).toBe(false);
  });

  it('keeps distinct repeated comments and emoji from the official surface', () => {
    const recent = new Map<string, number>();
    const first = makeChatEvent('youtube', 'yt-dom:first', 'same', textTokens('same'), 'alice');
    const second = makeChatEvent('youtube', 'yt-dom:second', 'same', textTokens('same'), 'alice');
    const emoji1 = makeChatEvent('youtube', 'yt-dom:emoji-1', 'emoji', [{kind: 'image', url: 'https://example.test/e.webp', alt: ':e:'}], 'alice');
    const emoji2 = makeChatEvent('youtube', 'yt-dom:emoji-2', 'emoji', [{kind: 'image', url: 'https://example.test/e.webp', alt: ':e:'}], 'alice');

    expect(isRecentDanmakuDuplicate(first, recent, 1000)).toBe(false);
    expect(isRecentDanmakuDuplicate(second, recent, 1001)).toBe(false);
    expect(isRecentDanmakuDuplicate(emoji1, recent, 1002)).toBe(false);
    expect(isRecentDanmakuDuplicate(emoji2, recent, 1003)).toBe(false);
  });

  it('deduplicates the same YouTube message across official DOM and fallback IDs', () => {
    const recent = new Map<string, number>();
    const official = makeChatEvent('youtube', 'yt-dom:message-1', 'hello');
    const fallback = makeChatEvent('youtube', 'message-1', 'hello');

    expect(isRecentDanmakuDuplicate(official, recent, 1000)).toBe(false);
    expect(isRecentDanmakuDuplicate(fallback, recent, 1001)).toBe(true);
  });

  it('does not silently truncate a high-flow backlog', () => {
    const queue = new DanmakuEventQueue();
    for (let index = 0; index < 25000; index += 1) {
      appendDanmakuEvent(queue, makeChatEvent('youtube', `message-${index}`, `text-${index}`));
    }

    expect(queue).toHaveLength(25000);
    const consumed = [] as string[];
    while (queue.length > 0) {
      consumed.push(consumeDanmakuEvent(queue)!.id);
    }
    expect(consumed).toHaveLength(25000);
    expect(consumed[0]).toBe('message-0');
    expect(consumed[24999]).toBe('message-24999');
    expect(queue).toHaveLength(0);
  });

  it('removes suppressed items without disturbing remaining dequeue order', () => {
    const queue = new DanmakuEventQueue();
    ['keep-1', 'drop', 'keep-2'].forEach(id => queue.append(makeChatEvent('youtube', id, id)));

    queue.removeWhere(event => event.id === 'drop');

    expect(consumeDanmakuEvent(queue)?.id).toBe('keep-1');
    expect(consumeDanmakuEvent(queue)?.id).toBe('keep-2');
    expect(consumeDanmakuEvent(queue)).toBeUndefined();
  });
});
