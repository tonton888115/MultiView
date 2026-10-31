import React from 'react';
import {ScrollView, Text} from 'react-native';
import renderer, {act, type ReactTestInstance, type ReactTestRenderer} from 'react-test-renderer';
import {StreamGrid, type ReorderTouchTargets} from '../StreamGrid';
import {computeGridLayout} from '../gridLayout';
import type {LayoutMode, StreamItem} from '../types';

// 視聴タブの並び替え(ドラッグ)を JS レベルで端から端まで再現するテスト。
// 旧実装は並び替えのたびにジェスチャー状態がリセットされ、セルが元の位置へ戻っていた。

const streams: StreamItem[] = [
  {id: 'youtube:a', platform: 'youtube', channel: 'a'},
  {id: 'twitch:b', platform: 'twitch', channel: 'b'},
  {id: 'kick:c', platform: 'kick', channel: 'c'},
];

const viewportWidth = 416;
const mountedTrees: ReactTestRenderer[] = [];

type Harness = {
  tree: ReactTestRenderer;
  onMove: jest.Mock;
  touchTargets: () => ReorderTouchTargets;
  cell: (id: string) => ReactTestInstance;
  scrollEnabled: () => boolean;
};

function touchEvent(pageX: number, pageY: number, options: {down?: boolean; identifier?: number} = {}) {
  const {down = true, identifier = 0} = options;
  const touch = {identifier, pageX, pageY, locationX: 0, locationY: 0, timestamp: 0, target: 1};
  return {
    nativeEvent: {...touch, touches: down ? [touch] : [], changedTouches: [touch]},
    persist() {},
  };
}

function mount(layoutMode: LayoutMode = 'stacked', items: StreamItem[] = streams): Harness {
  const onMove = jest.fn();
  let latestTargets: ReorderTouchTargets | null = null;
  const renderCell = (stream: StreamItem, touchTargets: ReorderTouchTargets) => {
    latestTargets = touchTargets;
    return <Text testID={`cell:${stream.id}`}>{stream.channel}</Text>;
  };
  let tree!: ReactTestRenderer;
  act(() => {
    tree = renderer.create(
      <StreamGrid streams={items} layoutMode={layoutMode} onMove={onMove} renderCell={renderCell} />,
    );
  });
  mountedTrees.push(tree);
  const viewport = tree.root.find(node => typeof node.type === 'string' && typeof node.props.onLayout === 'function');
  act(() => {
    viewport.props.onLayout({nativeEvent: {layout: {x: 0, y: 0, width: viewportWidth, height: 640}}});
  });
  const cell = (id: string) =>
    tree.root.find(
      node =>
        typeof node.type === 'string' &&
        typeof node.props.onMoveShouldSetResponderCapture === 'function' &&
        node.findAll(child => child.props.testID === `cell:${id}`).length > 0,
    );
  const scrollEnabled = () =>
    tree.root.find(node => typeof node.type === 'string' && 'scrollEnabled' in node.props).props.scrollEnabled;
  return {
    tree,
    onMove,
    touchTargets: () => {
      if (!latestTargets) {
        throw new Error('renderCell was not called');
      }
      return latestTargets;
    },
    cell,
    scrollEnabled,
  };
}

beforeEach(() => {
  jest.useFakeTimers();
  // 自動スクロールのフレームループはこのテストの対象外。
  jest.spyOn(globalThis, 'requestAnimationFrame').mockImplementation(() => 0);
  jest.spyOn(globalThis, 'cancelAnimationFrame').mockImplementation(() => undefined);
});

afterEach(() => {
  act(() => {
    jest.runOnlyPendingTimers();
    mountedTrees.splice(0).forEach(tree => tree.unmount());
  });
  jest.useRealTimers();
  jest.restoreAllMocks();
});

describe('StreamGrid drag reorder', () => {
  const slotHeight = computeGridLayout(3, 'stacked', viewportWidth).frames[0].height;

  it('moves a stream with the handle and commits once on release', () => {
    const harness = mount();
    const source = harness.cell('youtube:a');
    act(() => {
      harness.touchTargets().markHandleTouch();
      source.props.onTouchStart(touchEvent(300, 100));
    });
    expect(harness.scrollEnabled()).toBe(false);
    act(() => {
      source.props.onTouchMove(touchEvent(300, 100 + slotHeight * 0.6));
    });
    act(() => {
      source.props.onTouchMove(touchEvent(300, 100 + slotHeight * 1.1));
    });
    // ドラッグ中は確定しない(ネイティブビューの付け替えで映像が瞬かないように)。
    expect(harness.onMove).not.toHaveBeenCalled();
    act(() => {
      source.props.onTouchEnd(touchEvent(300, 100 + slotHeight * 1.1, {down: false}));
    });
    expect(harness.onMove).toHaveBeenCalledTimes(1);
    expect(harness.onMove).toHaveBeenCalledWith('youtube:a', 1);
    expect(harness.scrollEnabled()).toBe(true);
  });

  it('keeps tracking the finger after the preview target changes (no snap back)', () => {
    const harness = mount();
    const source = harness.cell('youtube:a');
    act(() => {
      harness.touchTargets().markHandleTouch();
      source.props.onTouchStart(touchEvent(300, 50));
    });
    // 1スロット分 → 2スロット分と連続で動かす。旧実装はここで dx/dy が 0 に戻り元の位置へ戻っていた。
    for (const step of [0.4, 0.8, 1.2, 1.6, 2.0, 2.2]) {
      act(() => {
        source.props.onTouchMove(touchEvent(300, 50 + slotHeight * step));
      });
    }
    act(() => {
      source.props.onTouchEnd(touchEvent(300, 50 + slotHeight * 2.2, {down: false}));
    });
    expect(harness.onMove).toHaveBeenCalledTimes(1);
    expect(harness.onMove).toHaveBeenCalledWith('youtube:a', 2);
  });

  it('moves upward from the last slot', () => {
    const harness = mount();
    const source = harness.cell('kick:c');
    act(() => {
      harness.touchTargets().markHandleTouch();
      source.props.onTouchStart(touchEvent(300, 500));
    });
    act(() => {
      source.props.onTouchMove(touchEvent(300, 500 - slotHeight * 2));
    });
    act(() => {
      source.props.onTouchEnd(touchEvent(300, 500 - slotHeight * 2, {down: false}));
    });
    expect(harness.onMove).toHaveBeenCalledWith('kick:c', 0);
  });

  it('moves between grid columns', () => {
    const harness = mount('grid');
    const frames = computeGridLayout(3, 'grid', viewportWidth).frames;
    const source = harness.cell('youtube:a');
    act(() => {
      harness.touchTargets().markHandleTouch();
      source.props.onTouchStart(touchEvent(150, 80));
    });
    act(() => {
      source.props.onTouchMove(touchEvent(150 + frames[1].x - frames[0].x, 80));
    });
    act(() => {
      source.props.onTouchEnd(touchEvent(150 + frames[1].x - frames[0].x, 80, {down: false}));
    });
    expect(harness.onMove).toHaveBeenCalledWith('youtube:a', 1);
  });

  it('starts dragging from a long press on the cell body', () => {
    const harness = mount();
    const source = harness.cell('twitch:b');
    act(() => {
      source.props.onTouchStart(touchEvent(200, 300));
    });
    expect(harness.scrollEnabled()).toBe(true);
    act(() => {
      jest.advanceTimersByTime(400);
    });
    expect(harness.scrollEnabled()).toBe(false);
    // 長押し後は外枠が JS レスポンダーを取りに行く(ネイティブのスクロール横取りを防ぐ)。
    expect(source.props.onMoveShouldSetResponderCapture()).toBe(true);
    act(() => {
      source.props.onTouchMove(touchEvent(200, 300 - slotHeight));
    });
    act(() => {
      source.props.onTouchEnd(touchEvent(200, 300 - slotHeight, {down: false}));
    });
    expect(harness.onMove).toHaveBeenCalledWith('twitch:b', 0);
  });

  it('does not start a long-press drag when the finger moves first (normal scrolling)', () => {
    const harness = mount();
    const source = harness.cell('twitch:b');
    act(() => {
      source.props.onTouchStart(touchEvent(200, 300));
      source.props.onTouchMove(touchEvent(200, 340));
      jest.advanceTimersByTime(400);
    });
    expect(harness.scrollEnabled()).toBe(true);
    expect(source.props.onMoveShouldSetResponderCapture()).toBe(false);
    act(() => {
      source.props.onTouchEnd(touchEvent(200, 340, {down: false}));
    });
    expect(harness.onMove).not.toHaveBeenCalled();
  });

  it('ignores long presses on controls (buttons / volume / comment bar)', () => {
    const harness = mount();
    const source = harness.cell('twitch:b');
    act(() => {
      harness.touchTargets().markControlTouch();
      source.props.onTouchStart(touchEvent(200, 300));
      jest.advanceTimersByTime(400);
    });
    expect(harness.scrollEnabled()).toBe(true);
  });

  it('cancels without committing when the touch is cancelled (e.g. a native gesture took over)', () => {
    const harness = mount();
    const source = harness.cell('youtube:a');
    act(() => {
      harness.touchTargets().markHandleTouch();
      source.props.onTouchStart(touchEvent(300, 100));
    });
    act(() => {
      source.props.onTouchMove(touchEvent(300, 100 + slotHeight));
    });
    act(() => {
      source.props.onTouchCancel(touchEvent(300, 100 + slotHeight, {down: false}));
    });
    expect(harness.onMove).not.toHaveBeenCalled();
    expect(harness.scrollEnabled()).toBe(true);
  });

  it('recovers when the end of a previous drag was lost', () => {
    const harness = mount();
    const source = harness.cell('youtube:a');
    act(() => {
      harness.touchTargets().markHandleTouch();
      source.props.onTouchStart(touchEvent(300, 100));
    });
    expect(harness.scrollEnabled()).toBe(false);
    // 終了イベントが来ないまま、新しい指1本のタッチが始まった。
    act(() => {
      harness.cell('kick:c').props.onTouchStart(touchEvent(200, 500));
    });
    expect(harness.scrollEnabled()).toBe(true);
    expect(harness.onMove).not.toHaveBeenCalled();
  });

  it('auto-scrolls when the dragged cell is pulled toward the bottom edge', () => {
    const many: StreamItem[] = Array.from({length: 6}, (_, index) => ({
      id: `twitch:s${index}`,
      platform: 'twitch' as const,
      channel: `s${index}`,
    }));
    const frames: Array<(time: number) => void> = [];
    (globalThis.requestAnimationFrame as unknown as jest.Mock).mockImplementation((callback: (time: number) => void) => {
      frames.push(callback);
      return frames.length;
    });
    const harness = mount('stacked', many);
    const scrollView = harness.tree.root.findByType(ScrollView).instance as {scrollTo: jest.Mock};
    scrollView.scrollTo.mockClear();
    const source = harness.cell('twitch:s0');
    act(() => {
      harness.touchTargets().markHandleTouch();
      source.props.onTouchStart(touchEvent(300, 100));
    });
    // 端の近くで掴んだだけ(指をまだ動かしていない)ではスクロールしない。
    act(() => {
      frames.splice(0).forEach(callback => callback(0));
    });
    expect(scrollView.scrollTo).not.toHaveBeenCalled();
    act(() => {
      source.props.onTouchMove(touchEvent(300, 630));
    });
    for (let frame = 0; frame < 5; frame += 1) {
      act(() => {
        frames.splice(0).forEach(callback => callback(0));
      });
    }
    expect(scrollView.scrollTo).toHaveBeenCalled();
    const lastCall = scrollView.scrollTo.mock.calls[scrollView.scrollTo.mock.calls.length - 1][0];
    expect(lastCall.y).toBeGreaterThan(0);
    act(() => {
      source.props.onTouchEnd(touchEvent(300, 630, {down: false}));
    });
    // スクロールした分だけ下のスロットへ移動している。
    expect(harness.onMove).toHaveBeenCalledTimes(1);
    expect(harness.onMove.mock.calls[0][0]).toBe('twitch:s0');
    expect(harness.onMove.mock.calls[0][1]).toBeGreaterThanOrEqual(2);
  });

  it('does not drag when there is only one stream', () => {
    const harness = mount('stacked', [streams[0]]);
    const source = harness.cell('youtube:a');
    act(() => {
      harness.touchTargets().markHandleTouch();
      source.props.onTouchStart(touchEvent(300, 100));
    });
    expect(harness.scrollEnabled()).toBe(true);
  });
});
