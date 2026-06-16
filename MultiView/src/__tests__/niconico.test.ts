import {parseNiconicoWatchData} from '../niconico';

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
