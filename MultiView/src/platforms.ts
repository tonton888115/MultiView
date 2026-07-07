import type {PlatformId} from './types';

export const platformIds: PlatformId[] = ['kick', 'twitch', 'youtube', 'niconico', 'twitcasting'];

export const platforms: Array<{id: PlatformId; label: string; hint: string; color: string}> = [
  {id: 'kick', label: 'Kick', hint: 'チャンネル名', color: '#53fc18'},
  {id: 'twitch', label: 'Twitch', hint: 'チャンネル名', color: '#9146ff'},
  {id: 'youtube', label: 'YouTube', hint: '動画ID / @handle / URL', color: '#ff3030'},
  {id: 'niconico', label: 'ニコ生', hint: '番組ID(lv...) / URL', color: '#ff8a20'},
  {id: 'twitcasting', label: 'ツイキャス', hint: 'ユーザーID', color: '#00a6ef'},
];

export function platformInfo(id: PlatformId) {
  return platforms.find(platform => platform.id === id) ?? platforms[0];
}

export function orderedPlatforms(order: PlatformId[]) {
  const merged = [...order, ...platformIds];
  return merged.reduce<PlatformId[]>((result, platform) => {
    if (platformIds.includes(platform) && !result.includes(platform)) {
      result.push(platform);
    }
    return result;
  }, []);
}
