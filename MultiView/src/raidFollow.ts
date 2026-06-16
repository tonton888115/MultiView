// iOS の RaidAutoFollow.swift / TwitchPlayer.twitchRaidTarget / KickPlayer.kickHostTarget
// を移植したレイド(ホスト)自動追従ロジック。
//
// チャットクライアント(chat.ts)はプレイヤー階層の奥(DanmakuOverlay)で動くため、
// onRaid を props で多層に通すのを避け、module-level のハンドラ経由で App へ通知する。
// App 側が settings.autoFollowRaids を見て streams へ追加し視聴タブへ切り替える。

import type {PlatformId} from './types';

type RaidHandler = (platform: PlatformId, channel: string) => void;

let raidHandler: RaidHandler | null = null;

export function setRaidHandler(handler: RaidHandler | null): void {
  raidHandler = handler;
}

// iOS RaidAutoFollow.normalize 相当。
export function normalizeChannel(raw: string, platform: PlatformId): string {
  let value = raw.trim().replace(/^[@#]+/, '');
  const twIndex = value.toLowerCase().indexOf('twitch.tv/');
  if (twIndex >= 0) {
    value = value.slice(twIndex + 'twitch.tv/'.length);
  }
  const kickIndex = value.toLowerCase().indexOf('kick.com/');
  if (kickIndex >= 0) {
    value = value.slice(kickIndex + 'kick.com/'.length);
  }
  value = value.split(/[/?#\s\n\t.,)\]」]/)[0] ?? value;
  return platform === 'twitch' ? value.toLowerCase() : value;
}

// iOS RaidAutoFollow.follow 相当。正規化+自ホスト除外の上でハンドラへ通知する。
export function reportRaid(platform: PlatformId, rawChannel: string, currentChannel: string): void {
  const channel = normalizeChannel(rawChannel, platform);
  const current = normalizeChannel(currentChannel, platform);
  if (!channel || channel.toLowerCase() === current.toLowerCase()) {
    return;
  }
  raidHandler?.(platform, channel);
}

// iOS TwitchPlayer.twitchRaidTarget 相当。USERNOTICE の raid 用タグ→本文の順で対象を取る。
const twitchTargetKeys = [
  'msg-param-target-login',
  'msg-param-target_user_login',
  'msg-param-targetuserlogin',
  'msg-param-to-broadcaster-user-login',
  'msg-param-raid-target',
  'msg-param-channel',
];

export function twitchRaidTarget(tags: Record<string, string>, body: string): string | null {
  for (const key of twitchTargetKeys) {
    const value = tags[key];
    if (value && value.trim()) {
      return normalizeChannel(value, 'twitch');
    }
  }
  const detected = detectTarget(body, 'twitch');
  return detected && detected.platform === 'twitch' ? detected.channel : null;
}

// iOS KickPlayer.kickHostTarget 相当。host_username(発信元)は無視し、宛先 slug のみ取る。
const kickNestedKeys = ['hosted', 'channel', 'target_channel', 'raid_target', 'target', 'destination', 'to_channel', 'host'];
const kickSlugKeys = ['slug', 'username', 'name'];
const kickDirectKeys = ['slug', 'target_slug', 'host_slug'];

export function kickHostTarget(payload: any): string | null {
  if (!payload || typeof payload !== 'object') {
    return null;
  }
  for (const key of kickNestedKeys) {
    const nested = payload[key];
    if (nested && typeof nested === 'object') {
      for (const slugKey of kickSlugKeys) {
        const slug = nested[slugKey];
        if (typeof slug === 'string' && slug.trim()) {
          return slug.trim();
        }
      }
    }
    if (typeof nested === 'string' && nested.trim()) {
      return nested.trim();
    }
  }
  for (const key of kickDirectKeys) {
    const slug = payload[key];
    if (typeof slug === 'string' && slug.trim()) {
      return slug.trim();
    }
  }
  return null;
}

// iOS RaidAutoFollow.detectTarget(text) 相当。raid/host キーワードがある時だけ URL/メンションを拾う。
export function detectTarget(
  text: string,
  preferredPlatform: PlatformId,
): {platform: PlatformId; channel: string} | null {
  const lower = text.toLowerCase();
  if (!/raid|raiding|レイド|host|hosting|ホスト/.test(lower)) {
    return null;
  }
  const linked = firstStreamURL(text);
  if (linked) {
    return linked;
  }
  return plainMentionTarget(text, preferredPlatform);
}

function firstStreamURL(text: string): {platform: PlatformId; channel: string} | null {
  const matches = text.match(/https?:\/\/[^\s<>"']+/g);
  if (!matches) {
    return null;
  }
  for (const raw of matches) {
    let url: URL;
    try {
      url = new URL(raw.replace(/[.,)\]」]+$/, ''));
    } catch {
      continue;
    }
    const host = url.hostname.replace(/^www\./, '').toLowerCase();
    const first = url.pathname.split('/').filter(Boolean)[0];
    if (!first) {
      continue;
    }
    if (host === 'twitch.tv' || host === 'm.twitch.tv') {
      const channel = normalizeChannel(first, 'twitch');
      if (channel) {
        return {platform: 'twitch', channel};
      }
    }
    if (host === 'kick.com') {
      const channel = normalizeChannel(first, 'kick');
      if (channel) {
        return {platform: 'kick', channel};
      }
    }
  }
  return null;
}

function plainMentionTarget(
  text: string,
  preferredPlatform: PlatformId,
): {platform: PlatformId; channel: string} | null {
  const match = text.match(/(?:raid(?:ing)?|レイド|host(?:ing)?|ホスト)[^\w@#]{0,24}@?([A-Za-z0-9_.-]{2,32})/i);
  if (!match?.[1]) {
    return null;
  }
  const channel = normalizeChannel(match[1], preferredPlatform);
  const ignored = ['to', 'into', 'over', 'the', 'a', 'channel', 'チャンネル'];
  if (!channel || ignored.includes(channel.toLowerCase())) {
    return null;
  }
  return {platform: preferredPlatform, channel};
}
