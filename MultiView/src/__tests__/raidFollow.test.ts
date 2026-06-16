import {
  detectTarget,
  kickHostTarget,
  normalizeChannel,
  reportRaid,
  setRaidHandler,
  twitchRaidTarget,
} from '../raidFollow';

describe('raid auto-follow (iOS RaidAutoFollow parity)', () => {
  afterEach(() => setRaidHandler(null));

  it('normalizes channels like iOS (strips @, urls, lowercases twitch)', () => {
    expect(normalizeChannel('@Shroud', 'twitch')).toBe('shroud');
    expect(normalizeChannel('https://twitch.tv/Shroud', 'twitch')).toBe('shroud');
    expect(normalizeChannel('kick.com/Trainwreckstv', 'kick')).toBe('Trainwreckstv');
    expect(normalizeChannel('xqc/clips', 'twitch')).toBe('xqc');
  });

  it('reads the twitch raid target from USERNOTICE tags', () => {
    expect(twitchRaidTarget({'msg-param-target-login': 'PokiMane'}, '')).toBe('pokimane');
    expect(twitchRaidTarget({'msg-param-channel': 'summit1g'}, '')).toBe('summit1g');
    // body fallback only when a raid keyword is present
    expect(twitchRaidTarget({}, 'raiding https://twitch.tv/CohhCarnage now')).toBe('cohhcarnage');
    expect(twitchRaidTarget({}, 'just a normal chat message')).toBeNull();
  });

  it('reads the kick host target from event payloads and ignores the source', () => {
    expect(kickHostTarget({hosted: {slug: 'destiny'}})).toBe('destiny');
    expect(kickHostTarget({channel: {username: 'Adin'}})).toBe('Adin');
    expect(kickHostTarget({target_slug: 'xqc'})).toBe('xqc');
    // host_username is the source and must not be picked up
    expect(kickHostTarget({host_username: 'someoneElse'})).toBeNull();
    expect(kickHostTarget({})).toBeNull();
    expect(kickHostTarget(null)).toBeNull();
  });

  it('detects targets from text only when a raid/host keyword is present', () => {
    expect(detectTarget('raid over to https://kick.com/Asmon', 'twitch')).toEqual({platform: 'kick', channel: 'Asmon'});
    expect(detectTarget('ホスト @lirik へ', 'twitch')).toEqual({platform: 'twitch', channel: 'lirik'});
    expect(detectTarget('check out twitch.tv/foo', 'twitch')).toBeNull(); // no raid keyword
  });

  it('fires the handler except for self-host, after normalizing', () => {
    const calls: Array<[string, string]> = [];
    setRaidHandler((platform, channel) => calls.push([platform, channel]));

    reportRaid('twitch', '@NewStreamer', 'currentChannel');
    reportRaid('twitch', 'CurrentChannel', 'currentChannel'); // self-host -> ignored
    reportRaid('kick', '', 'cur'); // empty -> ignored

    expect(calls).toEqual([['twitch', 'newstreamer']]);
  });
});
