import {clearLiveYouTubeVideoIDCache, resolveLiveYouTubeVideoID} from '../playback';

type FetchMock = jest.Mock<Promise<{ok: boolean; url: string; text: () => Promise<string>}>, [string, unknown?]>;

const originalFetch = globalThis.fetch;

function installFetch(responses: Array<{url: string; html?: string; ok?: boolean}>): FetchMock {
  let index = 0;
  const mock: FetchMock = jest.fn(async (_url: string, _init?: unknown) => {
    const response = responses[Math.min(index, responses.length - 1)];
    index += 1;
    return {ok: response.ok ?? true, url: response.url, text: async () => response.html ?? ''};
  });
  (globalThis as {fetch: unknown}).fetch = mock;
  return mock;
}

beforeEach(() => {
  clearLiveYouTubeVideoIDCache();
});

afterAll(() => {
  (globalThis as {fetch: unknown}).fetch = originalFetch;
});

describe('resolveLiveYouTubeVideoID sharing', () => {
  it('shares one /live request between concurrent callers (player, chat, bridge, viewer count)', async () => {
    const fetchMock = installFetch([{url: 'https://www.youtube.com/watch?v=abcdefghijk'}]);
    const results = await Promise.all([
      resolveLiveYouTubeVideoID('@channel'),
      resolveLiveYouTubeVideoID('@channel'),
      resolveLiveYouTubeVideoID('channel'),
    ]);
    expect(results).toEqual(['abcdefghijk', 'abcdefghijk', 'abcdefghijk']);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('reuses a recent result instead of refetching the heavy page', async () => {
    const fetchMock = installFetch([{url: 'https://www.youtube.com/watch?v=abcdefghijk'}]);
    await resolveLiveYouTubeVideoID('@channel');
    await resolveLiveYouTubeVideoID('@channel');
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('does not remember failures, so a stream that goes live is picked up on the next try', async () => {
    const fetchMock = installFetch([
      {url: 'https://www.youtube.com/@channel/live', html: '<html>offline</html>'},
      {url: 'https://www.youtube.com/@channel/live', html: '<html>offline</html>'},
      {url: 'https://www.youtube.com/watch?v=zyxwvutsrqp'},
    ]);
    expect(await resolveLiveYouTubeVideoID('@channel')).toBeNull();
    expect(await resolveLiveYouTubeVideoID('@channel')).toBe('zyxwvutsrqp');
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });
});
