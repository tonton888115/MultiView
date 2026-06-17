import {
  giftEventFromChatEvent,
  publishGiftEvent,
  subscribeGiftEvents,
  type GiftEvent,
} from '../giftEvents';
import {makeChatEvent} from '../danmaku';

function giftEvent(id: string, text = 'thanks'): GiftEvent {
  return {
    id,
    platform: 'youtube',
    text,
    headline: '$5.00',
    kind: 'superchat',
    createdAt: Date.now(),
  };
}

describe('gift event pub/sub', () => {
  it('delivers by stream id, isolates other streams, and unsubscribes', () => {
    const streamA = `youtube:a:${Date.now()}`;
    const streamB = `youtube:b:${Date.now()}`;
    const callsA: GiftEvent[] = [];
    const callsB: GiftEvent[] = [];
    const unsubscribeA = subscribeGiftEvents(streamA, event => callsA.push(event));
    const unsubscribeB = subscribeGiftEvents(streamB, event => callsB.push(event));
    const eventA = giftEvent('gift-a');
    const eventB = giftEvent('gift-b');

    publishGiftEvent(streamA, eventA);
    publishGiftEvent(streamB, eventB);

    expect(callsA).toEqual([eventA]);
    expect(callsB).toEqual([eventB]);

    unsubscribeA();
    publishGiftEvent(streamA, giftEvent('gift-a-2'));

    expect(callsA).toEqual([eventA]);

    unsubscribeB();
  });

  it('swallows listener errors and keeps notifying remaining listeners', () => {
    const streamId = `youtube:error:${Date.now()}`;
    const calls: GiftEvent[] = [];
    const unsubscribeThrowing = subscribeGiftEvents(streamId, () => {
      throw new Error('listener failed');
    });
    const unsubscribeRecording = subscribeGiftEvents(streamId, event => calls.push(event));
    const event = giftEvent('gift-error');

    expect(() => publishGiftEvent(streamId, event)).not.toThrow();
    expect(calls).toEqual([event]);

    unsubscribeThrowing();
    unsubscribeRecording();
  });
});

describe('giftEventFromChatEvent', () => {
  it('classifies superchat, sub, and gift events from superInfo', () => {
    const superchat = makeChatEvent('youtube', 'paid-1', 'nice stream', undefined, 'alice', '$5.00');
    const sub = makeChatEvent('twitch', 'sub-1', 'staying subscribed', undefined, 'bob', '12 month sub');
    const gift = makeChatEvent('youtube', 'gift-1', 'enjoy', undefined, 'carol', 'gift membership');

    expect(giftEventFromChatEvent('youtube:paid', superchat)).toMatchObject({
      id: 'paid-1',
      platform: 'youtube',
      author: 'alice',
      text: 'nice stream',
      headline: '$5.00',
      kind: 'superchat',
    });
    expect(giftEventFromChatEvent('twitch:sub', sub)).toMatchObject({
      id: 'sub-1',
      platform: 'twitch',
      author: 'bob',
      text: 'staying subscribed',
      headline: '12 month sub',
      kind: 'sub',
    });
    expect(giftEventFromChatEvent('youtube:gift', gift)).toMatchObject({
      id: 'gift-1',
      platform: 'youtube',
      author: 'carol',
      text: 'enjoy',
      headline: 'gift membership',
      kind: 'gift',
    });
  });

  it('returns null when there is no superInfo', () => {
    const event = makeChatEvent('youtube', 'plain-1', 'hello');

    expect(giftEventFromChatEvent('youtube:plain', event)).toBeNull();
  });
});
