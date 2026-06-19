import {parseNiconicoWatchData} from '../niconico';
import {TWITCASTING_STREAM_PRIORITY, pickTwitcastingHlsUrl} from '../twitcasting';

// data-props は HTML エンティティ化された JSON。テストでは引用符だけ &quot; にする。
function dataProps(obj: unknown): string {
  return JSON.stringify(obj).replace(/"/g, '&quot;');
}

describe('niconico watch-data parsing (iOS NiconicoPlayer parity)', () => {
  it('reads the new pageContents.playerParams.wsEndPoint shape', () => {
    const props = {
      pageContents: {watchInformation: {playerParams: {wsEndPoint: {url: 'wss://a.example/ws'}}}},
      constants: {requestInfo: {frontendId: 12}},
    };
    const html = `<script id="embedded-data" data-props="${dataProps(props)}"></script>`;
    expect(parseNiconicoWatchData(html)).toEqual({wsUrl: 'wss://a.example/ws', frontendId: '12'});
  });

  it('reads the legacy site.relive.webSocketUrl shape', () => {
    const props = {site: {relive: {webSocketUrl: 'wss://b.example/ws'}, frontendId: 9}};
    const html = `<script id="embedded-data" data-props="${dataProps(props)}"></script>`;
    expect(parseNiconicoWatchData(html)).toEqual({wsUrl: 'wss://b.example/ws', frontendId: '9'});
  });

  it('returns null when no websocket url is present', () => {
    expect(parseNiconicoWatchData('<html>nope</html>')).toBeNull();
    const props = {site: {name: 'x'}};
    expect(parseNiconicoWatchData(`<div id="embedded-data" data-props="${dataProps(props)}"></div>`)).toBeNull();
  });
});

describe('twitcasting HLS stream priority', () => {
  it.each(TWITCASTING_STREAM_PRIORITY)('returns the %s stream when it is the best available priority', key => {
    const streams = Object.fromEntries(
      TWITCASTING_STREAM_PRIORITY.map(priority => [priority, priority === key ? `https://example.com/${priority}.m3u8` : '']),
    );
    expect(pickTwitcastingHlsUrl(streams)).toBe(`https://example.com/${key}.m3u8`);
  });

  it('returns any stream key when no priority key is present', () => {
    expect(pickTwitcastingHlsUrl({other: 'https://example.com/other.m3u8'})).toBe('https://example.com/other.m3u8');
  });

  it('returns null for empty or null streams', () => {
    expect(pickTwitcastingHlsUrl({})).toBeNull();
    expect(pickTwitcastingHlsUrl(null)).toBeNull();
  });
});
