import {compactHandoffCode, decodeHandoff, encodeBase64Utf8, handoffURL} from '../handoff';
import {StreamItem} from '../types';

const streams: StreamItem[] = [
  {id: 'twitch:fps_shaka', platform: 'twitch', channel: 'fps_shaka'},
  {id: 'niconico:lv123', platform: 'niconico', channel: 'lv123'},
];

describe('handoff QR compatibility contract', () => {
  it('round-trips the compact code (raw base64, iOS QR format)', () => {
    const code = compactHandoffCode(streams, 'grid');
    const decoded = decodeHandoff(code);
    expect(decoded.streams).toEqual([
      {platform: 'twitch', channel: 'fps_shaka'},
      {platform: 'niconico', channel: 'lv123'},
    ]);
    expect(decoded.settings).toEqual({layoutMode: 'grid'});
  });

  it('round-trips the URL form (Android QR format, also accepted by iOS decode)', () => {
    const url = handoffURL(streams, 'stacked');
    expect(url.startsWith('multiview://handoff?d=')).toBe(true);
    const decoded = decodeHandoff(url);
    expect(decoded.streams).toHaveLength(2);
    expect(decoded.settings).toEqual({layoutMode: 'stacked'});
  });

  it('accepts an iOS HandoffPayload JSON encoded as base64 (v:1, s:[{p,c}], layout)', () => {
    // iOS Handoff.swift encodedCode() = base64(JSON {v,s,layout})
    const iosCode = encodeBase64Utf8(JSON.stringify({v: 1, s: [{p: 'youtube', c: '@LofiGirl'}], layout: 'grid'}));
    const decoded = decodeHandoff(iosCode);
    expect(decoded.streams).toEqual([{platform: 'youtube', channel: '@LofiGirl'}]);
  });

  it('handles multibyte channels (UTF-8) through the QR URL form', () => {
    const multibyte: StreamItem[] = [{id: 'twitcasting:配信者', platform: 'twitcasting', channel: '配信者'}];
    const decoded = decodeHandoff(handoffURL(multibyte, 'grid'));
    expect(decoded.streams).toEqual([{platform: 'twitcasting', channel: '配信者'}]);
  });

  it('rejects garbage input', () => {
    expect(() => decodeHandoff('not-a-code')).toThrow();
    expect(() => decodeHandoff('')).toThrow();
  });
});
