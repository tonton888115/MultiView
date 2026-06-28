import React from 'react';
import TestRenderer, {act} from 'react-test-renderer';
import {DanmakuOverlay} from '../DanmakuOverlay';
import type {AppSettings, StreamItem} from '../types';

const mockStop = jest.fn();
const mockStartChatClient = jest.fn((..._args: unknown[]) => ({stop: mockStop}));

jest.mock('../chat', () => ({
  startChatClient: (...args: unknown[]) => mockStartChatClient(...args),
}));
jest.mock('../YouTubeOfficialChatBridge', () => ({
  YouTubeOfficialChatBridge: () => null,
}));
jest.mock('../giftEvents', () => ({
  giftEventFromChatEvent: () => null,
  publishGiftEvent: jest.fn(),
}));

const stream: StreamItem = {id: 'twitch:test', platform: 'twitch', channel: 'test'};
const settings: AppSettings = {
  settingsVersion: 4,
  showChat: false,
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
};

describe('DanmakuOverlay lifecycle', () => {
  beforeEach(() => {
    mockStartChatClient.mockClear();
    mockStop.mockClear();
  });

  it('keeps the official chat client running when only the focused chat pane is hidden', async () => {
    let renderer!: TestRenderer.ReactTestRenderer;
    await act(async () => {
      renderer = TestRenderer.create(<DanmakuOverlay stream={stream} settings={settings} />);
    });
    expect(mockStartChatClient).toHaveBeenCalledTimes(1);

    const layoutViews = renderer.root.findAll(node => typeof node.props.onLayout === 'function');
    const layoutView = layoutViews[0];
    expect(layoutView).toBeDefined();
    await act(async () => {
      layoutView!.props.onLayout({nativeEvent: {layout: {width: 960, height: 540}}});
    });
    expect(mockStartChatClient).toHaveBeenCalledTimes(1);

    await act(async () => {
      renderer.update(
        <DanmakuOverlay stream={stream} settings={{...settings, showChat: true}} />,
      );
    });
    expect(mockStartChatClient).toHaveBeenCalledTimes(1);

    await act(async () => renderer.unmount());
    expect(mockStop).toHaveBeenCalledTimes(1);
  });

  it('does not connect when danmaku itself is disabled', async () => {
    let renderer!: TestRenderer.ReactTestRenderer;
    await act(async () => {
      renderer = TestRenderer.create(
        <DanmakuOverlay stream={stream} settings={{...settings, showDanmaku: false}} />,
      );
    });
    expect(mockStartChatClient).not.toHaveBeenCalled();
    expect(renderer.toJSON()).toBeNull();
    await act(async () => renderer.unmount());
  });

  it('stops and restarts the chat client when danmaku is toggled off and on', async () => {
    let renderer!: TestRenderer.ReactTestRenderer;
    await act(async () => {
      renderer = TestRenderer.create(<DanmakuOverlay stream={stream} settings={settings} />);
    });
    expect(mockStartChatClient).toHaveBeenCalledTimes(1);

    await act(async () => {
      renderer.update(
        <DanmakuOverlay stream={stream} settings={{...settings, showDanmaku: false}} />,
      );
    });
    expect(renderer.toJSON()).toBeNull();
    expect(mockStop).toHaveBeenCalledTimes(1);

    await act(async () => {
      renderer.update(<DanmakuOverlay stream={stream} settings={settings} />);
    });
    expect(mockStartChatClient).toHaveBeenCalledTimes(2);
    expect(renderer.toJSON()).not.toBeNull();

    await act(async () => renderer.unmount());
    expect(mockStop).toHaveBeenCalledTimes(2);
  });
});
