import {parseStreamURL} from '../streamURL';

describe('stream URL parsing from ranking pages', () => {
  it('parses niconico watch and soraweb ranking links', () => {
    expect(parseStreamURL('http://live.nicovideo.jp/watch/lv123456789')).toEqual({
      platform: 'niconico',
      channel: 'lv123456789',
    });
    expect(
      parseStreamURL(
        'http://live-info.soraweb.net/?site=nico&id=123&liveNo=123456789&link=http%3A%2F%2Flive.nicovideo.jp%2Fwatch%2Flv987654321',
      ),
    ).toEqual({
      platform: 'niconico',
      channel: 'lv987654321',
    });
    expect(parseStreamURL('http://live-info.soraweb.net/?site=nico&id=123&liveNo=123456789')).toEqual({
      platform: 'niconico',
      channel: 'lv123456789',
    });
  });

  it('rejects niconico user live-program pages', () => {
    expect(parseStreamURL('https://www.nicovideo.jp/user/12345/live_programs')).toBeNull();
  });

  it('parses twitcasting direct and soraweb ranking links', () => {
    expect(parseStreamURL('https://twitcasting.tv/c%3Aabzou_sub')).toEqual({
      platform: 'twitcasting',
      channel: 'c:abzou_sub',
    });
    expect(parseStreamURL('https://twitcasting.tv/jr_hirata/movie/836955222')).toEqual({
      platform: 'twitcasting',
      channel: 'jr_hirata',
    });
    expect(
      parseStreamURL(
        'https://live-info.soraweb.net/?site=twitcasting&link=https%3A%2F%2Ftwitcasting.tv%2Fc%253Agengorou_2nd',
      ),
    ).toEqual({
      platform: 'twitcasting',
      channel: 'c:gengorou_2nd',
    });
  });
});
