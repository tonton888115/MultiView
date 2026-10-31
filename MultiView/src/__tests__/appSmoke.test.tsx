import React from 'react';
import renderer, {act, type ReactTestInstance, type ReactTestRenderer} from 'react-test-renderer';
import App from '../../App';

// 端末で動かせない環境向けのスモークテスト: App 全体を描画し、保存済みの配信が視聴タブに並び、
// ハンドル(≡)のドラッグで並び順が保存されるところまでを JS レベルで通す。

const mockStore = new Map<string, string>();

jest.mock('@react-native-async-storage/async-storage', () => ({
  __esModule: true,
  default: {
    getItem: jest.fn(async (key: string) => mockStore.get(key) ?? null),
    setItem: jest.fn(async (key: string, value: string) => {
      mockStore.set(key, value);
    }),
    removeItem: jest.fn(async (key: string) => {
      mockStore.delete(key);
    }),
  },
}));

jest.mock('react-native-webview', () => {
  const ReactModule = require('react');
  const {View} = require('react-native');
  const WebView = ReactModule.forwardRef((_props: unknown, ref: unknown) => {
    ReactModule.useImperativeHandle(ref, () => ({injectJavaScript: () => undefined}));
    return ReactModule.createElement(View, {testID: 'mock-webview'});
  });
  return {__esModule: true, WebView, default: WebView};
});

jest.mock('react-native-safe-area-context', () => {
  const ReactModule = require('react');
  const {View} = require('react-native');
  return {
    SafeAreaProvider: ({children}: {children: unknown}) => ReactModule.createElement(ReactModule.Fragment, null, children),
    SafeAreaView: ({edges: _edges, ...props}: Record<string, unknown>) => ReactModule.createElement(View, props),
  };
});

class MockWebSocket {
  onopen: (() => void) | null = null;
  onmessage: ((event: unknown) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  send() {}
  close() {}
}

const originalFetch = globalThis.fetch;
const originalWebSocket = (globalThis as {WebSocket?: unknown}).WebSocket;

beforeEach(() => {
  jest.useFakeTimers();
  mockStore.clear();
  (globalThis as {fetch: unknown}).fetch = jest.fn(async () => ({
    ok: false,
    status: 503,
    url: '',
    json: async () => ({}),
    text: async () => '',
  }));
  (globalThis as {WebSocket: unknown}).WebSocket = MockWebSocket;
  jest.spyOn(globalThis, 'requestAnimationFrame').mockImplementation(() => 0);
  jest.spyOn(globalThis, 'cancelAnimationFrame').mockImplementation(() => undefined);
});

afterEach(() => {
  jest.useRealTimers();
  jest.restoreAllMocks();
  (globalThis as {fetch: unknown}).fetch = originalFetch;
  (globalThis as {WebSocket: unknown}).WebSocket = originalWebSocket;
});

async function flush() {
  await act(async () => {
    await Promise.resolve();
  });
  act(() => {
    jest.advanceTimersByTime(10);
  });
  await act(async () => {
    await Promise.resolve();
  });
}

function touch(pageX: number, pageY: number, down = true) {
  const point = {identifier: 0, pageX, pageY, locationX: 0, locationY: 0, timestamp: 0, target: 1};
  return {nativeEvent: {...point, touches: down ? [point] : [], changedTouches: [point]}, persist() {}};
}

function gridCells(tree: ReactTestRenderer): ReactTestInstance[] {
  // StreamGrid のセル外枠(音量スライダー等の PanResponder とは onTouchCancel の有無で区別)。
  // Animated.View とその中の View が同じ props を持つため、ハンドラ関数ごとに1つへまとめる。
  const seen = new Set<unknown>();
  return tree.root
    .findAll(
      node =>
        typeof node.type === 'string' &&
        typeof node.props.onMoveShouldSetResponderCapture === 'function' &&
        typeof node.props.onTouchCancel === 'function',
    )
    .filter(node => {
      if (seen.has(node.props.onTouchStart)) {
        return false;
      }
      seen.add(node.props.onTouchStart);
      return true;
    });
}

describe('App smoke test', () => {
  it('renders saved streams and persists a drag reorder', async () => {
    mockStore.set(
      'multiview.android.streams.v2',
      JSON.stringify([
        {platform: 'twitch', channel: 'alpha'},
        {platform: 'kick', channel: 'beta'},
        {platform: 'twitcasting', channel: 'gamma'},
      ]),
    );
    mockStore.set('multiview.android.settings.v2', JSON.stringify({layoutMode: 'stacked', showDanmaku: false}));

    let tree!: ReactTestRenderer;
    await act(async () => {
      tree = renderer.create(<App />);
    });
    await flush();
    await flush();

    expect(gridCells(tree)).toHaveLength(3);

    // StreamGrid のビューポート幅を確定させる。
    const viewport = tree.root.findAll(
      node =>
        typeof node.type === 'string' &&
        typeof node.props.onLayout === 'function' &&
        node.findAll(child => typeof child.props.onMoveShouldSetResponderCapture === 'function').length > 0,
    )[0];
    act(() => {
      viewport.props.onLayout({nativeEvent: {layout: {x: 0, y: 0, width: 416, height: 640}}});
    });

    // 描画順は id 順(kick:beta, twitcasting:gamma, twitch:alpha)で固定。twitch:alpha の ≡ を掴んで下へ。
    const alphaCell = gridCells(tree).find(
      cell => cell.findAll(node => node.props.stream?.id === 'twitch:alpha').length > 0,
    );
    expect(alphaCell).toBeDefined();
    const handle = alphaCell!.findAll(
      node => typeof node.type === 'string' && node.props.accessibilityLabel === '並び替え',
    )[0];

    act(() => {
      handle.props.onTouchStart(touch(380, 200));
      alphaCell!.props.onTouchStart(touch(380, 200));
    });
    act(() => {
      alphaCell!.props.onTouchMove(touch(380, 200 + 240 * 2));
    });
    act(() => {
      alphaCell!.props.onTouchEnd(touch(380, 200 + 240 * 2, false));
    });
    await flush();

    const saved = JSON.parse(mockStore.get('multiview.android.streams.v2') ?? '[]') as Array<{id: string}>;
    expect(saved.map(stream => stream.id)).toEqual(['kick:beta', 'twitcasting:gamma', 'twitch:alpha']);

    await act(async () => {
      tree.unmount();
    });
  });
});
