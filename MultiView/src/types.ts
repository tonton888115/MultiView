export type PlatformId = 'kick' | 'twitch' | 'youtube' | 'niconico' | 'twitcasting';
export type TabId = 'following' | 'ranking' | 'viewing' | 'settings';
export type LayoutMode = 'stacked' | 'grid';
export type PlaybackQuality = 'high' | 'economy';
export type NetworkType = 'wifi' | 'cellular' | 'other' | 'none';

export type StreamItem = {
  id: string;
  platform: PlatformId;
  channel: string;
};

export type AppSettings = {
  settingsVersion: number;
  showChat: boolean;
  showDanmaku: boolean;
  showEmotes: boolean;
  showViewerCount: boolean;
  playAudio: boolean;
  autoFollowRaids: boolean;
  blockWebAds: boolean;
  youtubePreferIframe: boolean;
  youtubeStableBuffer: boolean;
  layoutMode: LayoutMode;
  wifiQuality: PlaybackQuality;
  mobileQuality: PlaybackQuality;
  danmakuFontSize: number;
  danmakuSpeed: number;
  danmakuOpacity: number;
  danmakuMaxLines: number;
  danmakuMaxLength: number;
  niconicoLowLatency: boolean;
  showGiftEffects: boolean;
  giftSoundEnabled: boolean;
  niconicoShowGift: boolean;
  niconicoShowNicoad: boolean;
  niconicoShowNotification: boolean;
  autoEconomyOnManyStreams: boolean;
  platformOrder: PlatformId[];
};

export type PlaybackSource =
  | {
      kind: 'native';
      url: string;
      headers?: Record<string, string>;
      liveTargetOffsetMs?: number;
      label: string;
      status: string;
    }
  | {
      kind: 'youtube-iframe';
      videoId: string;
      label: string;
      status: string;
    }
  | {
      kind: 'web';
      url: string;
      label: string;
      status: string;
      reason?: string;
    }
  | {
      kind: 'error';
      label: string;
      status: string;
      reason: string;
      fallbackUrl?: string;
    };

export type Source = {
  label: string;
  platform: PlatformId;
  url: string;
};

export type DanmakuToken =
  | {
      kind: 'text';
      text: string;
    }
  | {
      kind: 'image';
      url: string;
      alt?: string;
    };

export type ChatEvent = {
  id: string;
  platform: PlatformId;
  author?: string;
  text: string;
  tokens: DanmakuToken[];
  superInfo?: string;
  highlighted?: boolean;
  createdAt: number;
};
