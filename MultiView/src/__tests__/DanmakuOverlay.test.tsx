import React from 'react';
import TestRenderer, {act} from 'react-test-renderer';
import {DanmakuOverlay, danmakuLaneCount} from '../DanmakuOverlay';
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

  it('drops events while the viewing tab is inactive and resumes fresh on return', async () => {
    let renderer!: TestRenderer.ReactTestRenderer;
    await act(async () => {
      renderer = TestRenderer.create(
        <DanmakuOverlay stream={stream} settings={settings} active={false} />,
      );
    });
    // 非表示中でも chat client は維持される(切断/再接続を繰り返さない)。
    expect(mockStartChatClient).toHaveBeenCalledTimes(1);
    jest.useFakeTimers();
    try {
      const layoutView = renderer.root.findAll(node => typeof node.props.onLayout === 'function')[0];
      act(() => {
        layoutView.props.onLayout({nativeEvent: {layout: {width: 750, height: 410}}});
      });
      const onEvent = mockStartChatClient.mock.calls[0][2] as (event: {
        id: string;
        platform: 'twitch';
        text: string;
        tokens: Array<{kind: 'text'; text: string}>;
        createdAt: number;
      }) => void;
      act(() => {
        onEvent({
          id: 'hidden',
          platform: 'twitch',
          text: 'hidden text',
          tokens: [{kind: 'text', text: 'hidden text'}],
          createdAt: Date.now(),
        });
        jest.advanceTimersByTime(20);
      });
      expect(renderer.root.findAll(node => node.props.children === 'hidden text')).toHaveLength(0);

      act(() => {
        renderer.update(<DanmakuOverlay stream={stream} settings={settings} active />);
      });
      act(() => {
        onEvent({
          id: 'resumed',
          platform: 'twitch',
          text: 'resumed text',
          tokens: [{kind: 'text', text: 'resumed text'}],
          createdAt: Date.now(),
        });
        // 既存テストと同じ 20ms: drain(16ms) 後かつモック環境の即時アニメ完了に伴う
        // 除去タイマー(+16ms)より前に表示を観測する。
        jest.advanceTimersByTime(20);
      });
      // 復帰後は新規イベントから描画を再開し、非表示中のイベントは復活しない。
      expect(renderer.root.findAll(node => node.props.children === 'resumed text')).not.toHaveLength(0);
      expect(renderer.root.findAll(node => node.props.children === 'hidden text')).toHaveLength(0);
      expect(mockStop).not.toHaveBeenCalled();
    } finally {
      act(() => renderer.unmount());
      jest.runOnlyPendingTimers();
      jest.useRealTimers();
    }
  });

  it('clears in-flight comments when Fold geometry changes', async () => {
    let renderer!: TestRenderer.ReactTestRenderer;
    await act(async () => {
      renderer = TestRenderer.create(<DanmakuOverlay stream={stream} settings={settings} />);
    });
    jest.useFakeTimers();
    try {
      const layoutView = renderer.root.findAll(node => typeof node.props.onLayout === 'function')[0];
      act(() => {
        layoutView.props.onLayout({nativeEvent: {layout: {width: 750, height: 410}}});
      });
      const onEvent = mockStartChatClient.mock.calls[0][2] as (event: {
        id: string;
        platform: 'twitch';
        text: string;
        tokens: Array<{kind: 'text'; text: string}>;
        createdAt: number;
      }) => void;
      act(() => {
        onEvent({
          id: 'before-fold',
          platform: 'twitch',
          text: 'before fold',
          tokens: [{kind: 'text', text: 'before fold'}],
          createdAt: Date.now(),
        });
        jest.advanceTimersByTime(20);
      });
      expect(renderer.root.findAll(node => node.props.children === 'before fold')).not.toHaveLength(0);

      act(() => {
        layoutView.props.onLayout({nativeEvent: {layout: {width: 340, height: 185}}});
      });
      expect(renderer.root.findAll(node => node.props.children === 'before fold')).toHaveLength(0);
    } finally {
      if (renderer) {
        act(() => renderer.unmount());
      }
      jest.runOnlyPendingTimers();
      jest.useRealTimers();
    }
  });
});

describe('danmaku lane geometry', () => {
  it('keeps the final lane inside the measured overlay', () => {
    expect(danmakuLaneCount(100, 28, 0)).toBe(3);
    expect(6 + danmakuLaneCount(100, 28, 0) * 28).toBeLessThanOrEqual(100);
  });

  it('treats the configured line count as a cap on Fold grid cells', () => {
    expect(danmakuLaneCount(100, 28, 10)).toBe(3);
    expect(danmakuLaneCount(540, 28, 4)).toBe(4);
  });

  it('keeps one usable lane until valid layout metrics arrive', () => {
    expect(danmakuLaneCount(0, 28, 0)).toBe(1);
    expect(danmakuLaneCount(10, 28, 10)).toBe(1);
  });
});
