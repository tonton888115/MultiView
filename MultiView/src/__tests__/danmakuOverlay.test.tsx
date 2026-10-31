import React from 'react';
import renderer, {act, type ReactTestRenderer} from 'react-test-renderer';
import {DanmakuOverlay} from '../DanmakuOverlay';
import {makeChatEvent} from '../danmaku';
import type {AppSettings, ChatEvent, StreamItem} from '../types';

// チャット接続を差し替えて、DanmakuOverlay が接続を張り直すタイミングを数える。
// (jest.mock は babel-jest により import より前へ巻き上げられる)
const mockStartChatClient = jest.fn();
jest.mock('../chat', () => ({
  startChatClient: (...args: unknown[]) => mockStartChatClient(...args),
}));
// YouTube 公式チャット用の隠し WebView はこのテストでは使わない(Twitch で検証)。
jest.mock('../YouTubeOfficialChatBridge', () => ({
  YouTubeOfficialChatBridge: () => null,
}));

const stream: StreamItem = {id: 'twitch:alice', platform: 'twitch', channel: 'alice'};

function settings(overrides: Partial<AppSettings> = {}): AppSettings {
  return {
    settingsVersion: 3,
    showChat: true,
    showDanmaku: true,
    showEmotes: true,
    showViewerCount: true,
    playAudio: true,
    autoFollowRaids: false,
    blockWebAds: true,
    youtubePreferIframe: false,
    youtubeStableBuffer: true,
    layoutMode: 'stacked',
    wifiQuality: 'high',
    mobileQuality: 'economy',
    danmakuFontSize: 20,
    danmakuSpeed: 0.13,
    danmakuOpacity: 0.9,
    danmakuMaxLines: 0,
    danmakuMaxLength: 0,
    niconicoLowLatency: false,
    showGiftEffects: true,
    giftSoundEnabled: true,
    niconicoShowGift: true,
    niconicoShowNicoad: true,
    niconicoShowNotification: true,
    autoEconomyOnManyStreams: true,
    platformOrder: ['kick', 'twitch', 'youtube', 'niconico', 'twitcasting'],
    ...overrides,
  };
}

let emit: ((event: ChatEvent) => void) | null = null;
let stop: jest.Mock;

beforeEach(() => {
  jest.useFakeTimers();
  stop = jest.fn();
  mockStartChatClient.mockReset();
  mockStartChatClient.mockImplementation((_stream: StreamItem, _settings: AppSettings, onEvent: (event: ChatEvent) => void) => {
    emit = onEvent;
    return {stop};
  });
});

afterEach(() => {
  jest.useRealTimers();
});

function layoutOverlay(tree: ReactTestRenderer, width: number, height: number) {
  const overlay = tree.root.find(node => typeof node.type === 'string' && typeof node.props.onLayout === 'function');
  act(() => {
    overlay.props.onLayout({nativeEvent: {layout: {x: 0, y: 0, width, height}}});
  });
}

describe('DanmakuOverlay chat lifecycle', () => {
  it('keeps one chat connection across layout and unrelated settings changes', () => {
    let tree!: ReactTestRenderer;
    act(() => {
      tree = renderer.create(<DanmakuOverlay stream={stream} settings={settings()} />);
    });
    expect(mockStartChatClient).toHaveBeenCalledTimes(1);
    // 初回レイアウト(以前はここで必ず切断→再接続していた)。
    layoutOverlay(tree, 400, 225);
    layoutOverlay(tree, 300, 168);
    act(() => {
      tree.update(<DanmakuOverlay stream={stream} settings={settings({layoutMode: 'grid', danmakuOpacity: 0.5, danmakuFontSize: 26})} />);
    });
    expect(mockStartChatClient).toHaveBeenCalledTimes(1);
    expect(stop).not.toHaveBeenCalled();
    act(() => {
      tree.unmount();
    });
    expect(stop).toHaveBeenCalledTimes(1);
  });

  it('reconnects only when danmaku is toggled', () => {
    let tree!: ReactTestRenderer;
    act(() => {
      tree = renderer.create(<DanmakuOverlay stream={stream} settings={settings()} />);
    });
    act(() => {
      tree.update(<DanmakuOverlay stream={stream} settings={settings({showDanmaku: false})} />);
    });
    expect(stop).toHaveBeenCalledTimes(1);
    act(() => {
      tree.update(<DanmakuOverlay stream={stream} settings={settings()} />);
    });
    expect(mockStartChatClient).toHaveBeenCalledTimes(2);
    act(() => {
      tree.unmount();
    });
  });

  it('keeps queued comments across a resize and shows them once laid out', () => {
    let tree!: ReactTestRenderer;
    act(() => {
      tree = renderer.create(<DanmakuOverlay stream={stream} settings={settings()} />);
    });
    act(() => {
      emit?.(makeChatEvent('twitch', 'c1', 'こんにちは'));
      jest.advanceTimersByTime(50);
    });
    // まだ大きさが分からないので表示待ち(捨てない)。
    expect(tree.root.findAll(node => node.props.children === 'こんにちは')).toHaveLength(0);
    layoutOverlay(tree, 400, 225);
    act(() => {
      jest.advanceTimersByTime(200);
    });
    expect(tree.root.findAll(node => typeof node.type === 'string' && node.props.children === 'こんにちは').length).toBeGreaterThan(0);
    act(() => {
      tree.unmount();
    });
  });
});
