import {extractYouTubeChatSessionFromHTML, youtubeChatEventsFromAction} from '../chat';

describe('extractYouTubeChatSessionFromHTML', () => {
  it('falls back to the live_chat HTML when the watch page has no continuation', () => {
    const session = extractYouTubeChatSessionFromHTML([
      '<script>ytcfg.set({"INNERTUBE_API_KEY":"watch-key","INNERTUBE_CONTEXT":{"client":{"clientName":"WEB","clientVersion":"watch-version"}}});</script>',
      '<script>var ytInitialData = {"contents":{"liveChatRenderer":{"continuations":[{"invalidationContinuationData":{"continuation":"live-cont","timeoutMs":1500}}]}}};</script>',
    ]);

    expect(session.apiKey).toBe('watch-key');
    expect(session.continuation).toBe('live-cont');
    expect(session.context.client.clientVersion).toBe('watch-version');
  });
});

describe('youtubeChatEventsFromAction', () => {
  it('keeps every nested YouTube chat item and preserves emoji/sticker tokens', () => {
    const events = youtubeChatEventsFromAction({
      addChatItemAction: {
        item: {
          liveChatTextMessageRenderer: {
            id: 'plain-1',
            authorName: {simpleText: 'alice'},
            message: {runs: [{text: 'hello '}, {emoji: {shortcuts: [':yt:'], image: {thumbnails: [{url: '//example.test/yt.png', width: 48}]}}}]},
          },
        },
      },
      replayChatItemAction: {
        actions: [
          {
            addChatItemAction: {
              item: {
                liveChatTextMessageRenderer: {
                  id: 'plain-2',
                  authorName: {simpleText: 'bob'},
                  message: {runs: [{text: 'second comment'}]},
                },
              },
            },
          },
          {
            addChatItemAction: {
              item: {
                liveChatPaidStickerRenderer: {
                  id: 'sticker-1',
                  authorName: {simpleText: 'carol'},
                  purchaseAmountText: {simpleText: '$2.00'},
                  sticker: {
                    accessibility: {accessibilityData: {label: 'party sticker'}},
                    thumbnails: [{url: 'https://example.test/sticker.webp', width: 96}],
                  },
                },
              },
            },
          },
        ],
      },
    });

    expect(events.map(event => event.id)).toEqual(['plain-1', 'plain-2', 'sticker-1']);
    expect(events[0].tokens).toEqual([
      {kind: 'text', text: 'hello '},
      {kind: 'image', url: 'https://example.test/yt.png', alt: ':yt:'},
    ]);
    expect(events[2].text).toBe('party sticker');
    expect(events[2].superInfo).toBe('$2.00');
    expect(events[2].tokens).toEqual([{kind: 'image', url: 'https://example.test/sticker.webp', alt: 'party sticker'}]);
  });

  it('deduplicates recursive renderer hits by YouTube message id', () => {
    const renderer = {
      id: 'same-id',
      authorName: {simpleText: 'alice'},
      message: {runs: [{text: 'only once'}]},
    };
    const events = youtubeChatEventsFromAction({
      addChatItemAction: {item: {liveChatTextMessageRenderer: renderer}},
      nestedDuplicate: {liveChatTextMessageRenderer: renderer},
    });

    expect(events).toHaveLength(1);
    expect(events[0].text).toBe('only once');
  });

  it('keeps image-only YouTube custom emoji and membership gift renderers', () => {
    const events = youtubeChatEventsFromAction({
      addChatItemAction: {
        item: {
          liveChatTextMessageRenderer: {
            id: 'emoji-only',
            authorName: {simpleText: 'dave'},
            message: {
              runs: [
                {
                  emoji: {
                    shortcuts: [':wave:'],
                    image: {thumbnails: [{url: 'https://example.test/wave.webp', width: 64}]},
                  },
                },
              ],
            },
          },
        },
      },
      gift: {
        liveChatSponsorshipsGiftRedemptionAnnouncementRenderer: {
          id: 'gift-1',
          authorName: {simpleText: 'erin'},
          headerPrimaryText: {runs: [{text: 'gift membership received'}]},
          headerSubtext: {
            runs: [
              {text: 'thanks '},
              {
                emoji: {
                  shortcuts: [':spark:'],
                  image: {thumbnails: [{url: '//example.test/spark.gif', width: 48}]},
                },
              },
            ],
          },
        },
      },
    });

    expect(events.map(event => event.id)).toEqual(['emoji-only', 'gift-1']);
    expect(events[0].text).toBe(':wave:');
    expect(events[0].tokens).toEqual([{kind: 'image', url: 'https://example.test/wave.webp', alt: ':wave:'}]);
    expect(events[1].text).toContain('gift membership received');
    expect(events[1].tokens).toContainEqual({kind: 'image', url: 'https://example.test/spark.gif', alt: ':spark:'});
  });
});
