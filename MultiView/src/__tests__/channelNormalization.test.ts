import {chatURL, cleanChannel, makeStream, streamKey, webStreamURL} from '../playback';

describe('channel normalization (@handle handling per platform)', () => {
  it('keeps a leading @ for YouTube handles but strips it for other platforms', () => {
    expect(cleanChannel('@LofiGirl', 'youtube')).toBe('@LofiGirl');
    expect(cleanChannel('@xqc', 'kick')).toBe('xqc');
    expect(cleanChannel('@twitcaster', 'twitcasting')).toBe('twitcaster');
    expect(cleanChannel('@someone', 'twitch')).toBe('someone');
    expect(cleanChannel('lv123', 'niconico')).toBe('lv123');
  });

  it('normalizes stored channel/id at makeStream so downstream URLs are valid', () => {
    const kick = makeStream('kick', '@xqc');
    expect(kick.channel).toBe('xqc');
    expect(kick.id).toBe('kick:xqc');
    expect(webStreamURL(kick)).toBe('https://kick.com/xqc');

    const youtube = makeStream('youtube', '@LofiGirl');
    expect(youtube.channel).toBe('@LofiGirl');
    expect(webStreamURL(youtube)).toContain('@LofiGirl/live');
  });

  it('produces a working TwitCasting chat URL from an @-prefixed input', () => {
    const tc = makeStream('twitcasting', '@caster');
    expect(chatURL(tc)).toBe('https://twitcasting.tv/caster');
  });

  it('keeps streamKey stable regardless of a leading @ (dedup safety)', () => {
    expect(streamKey('kick', '@xQc')).toBe(streamKey('kick', 'xqc'));
    expect(streamKey('youtube', '@LofiGirl')).toBe('youtube:@lofigirl');
  });
});
