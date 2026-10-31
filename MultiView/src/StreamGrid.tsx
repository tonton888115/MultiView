// 視聴タブのセル一覧(スタック/グリッド)とドラッグ並び替え。
//
// 旧実装はセル内の PanResponder を index 依存の useMemo で作っていたため、並び替えで
// index が変わるたびにジェスチャー状態(dx/dy)が 0 へリセットされ、セルが元の位置へ
// 戻ってしまい「ドラッグしても場所が移動できない」状態だった。さらにドラッグ中に
// 毎回 streams を並べ替えていたので、ネイティブビューの付け替えで映像が瞬いていた。
//
// ここでは次の方針で作り直す:
//  - セルの描画順は id 順で固定し、位置は transform(ネイティブドライバ)だけで動かす。
//    並び替えてもネイティブビューは移動しないので、再生中の映像が途切れない。
//  - ドラッグ中は並び順を確定させず、他セルをプレビュー位置へアニメーションで退かせる。
//    指を離した時に一度だけ onMove で確定する(iOS ViewingController と同じ流れ)。
//  - ドラッグ状態はすべて ref で持ち、再レンダーでジェスチャーが壊れないようにする。
//  - ハンドル(≡)は触れた瞬間から、セル本体は長押しでドラッグ開始。開始と同時に
//    ScrollView のスクロールを止め、JS レスポンダーでネイティブのスクロール横取りも防ぐ。
//  - 画面端へ持っていくと自動スクロールする。

import React, {memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState} from 'react';
import {
  Animated,
  Easing,
  ScrollView,
  StyleSheet,
  View,
  useWindowDimensions,
  type GestureResponderEvent,
  type LayoutChangeEvent,
  type NativeScrollEvent,
  type NativeSyntheticEvent,
} from 'react-native';
import {
  autoScrollStep,
  computeGridLayout,
  gridCellGutter,
  moveItem,
  previewTransform,
  slotIndexAtPoint,
  type SlotFrame,
} from './gridLayout';
import type {LayoutMode, StreamItem} from './types';

// セル内の要素から呼ぶ印付け。セル外枠(GridCell)の onTouchStart より先に子の
// onTouchStart が呼ばれる(バブリング順)ので、どこから触り始めたかを外枠で判別できる。
export type ReorderTouchTargets = {
  // 並び替えハンドル: 触れた瞬間にドラッグを開始する。
  markHandleTouch: () => void;
  // ボタン/音量スライダー/コメント欄: 長押しドラッグを開始しない。
  markControlTouch: () => void;
};

type Props = {
  streams: StreamItem[];
  layoutMode: LayoutMode;
  onMove: (id: string, targetIndex: number) => void;
  renderCell: (stream: StreamItem, touchTargets: ReorderTouchTargets) => React.ReactNode;
};

type CellTarget = {x: number; y: number; scale: number};

type CellValues = {
  x: Animated.Value;
  y: Animated.Value;
  scale: Animated.Value;
  // 最後にアニメーション/設定した目標。null は「必ず次の settle で動かす」。
  target: CellTarget | null;
  width: number;
  height: number;
};

type TouchId = number | string;

type DragSession = {
  id: string;
  touchId: TouchId;
  mode: 'handle' | 'longpress';
  fromIndex: number;
  targetIndex: number;
  orderIds: string[];
  frames: SlotFrame[];
  layoutKey: string;
  orderKey: string;
  startPageX: number;
  startPageY: number;
  startScrollY: number;
  pageX: number;
  pageY: number;
};

type PendingLongPress = {
  id: string;
  touchId: TouchId;
  startPageX: number;
  startPageY: number;
  pageX: number;
  pageY: number;
  timer: ReturnType<typeof setTimeout>;
};

const longPressMs = 320;
const longPressSlop = 10;
const liftScale = 1.035;
const shiftDurationMs = 200;
const settleDurationMs = 220;
const autoScrollMaxStep = 18;
const autoScrollArmDistance = 12;

function sameTarget(a: CellTarget | null, b: CellTarget): boolean {
  return !!a && Math.abs(a.x - b.x) < 0.5 && Math.abs(a.y - b.y) < 0.5 && Math.abs(a.scale - b.scale) < 0.001;
}

function findTouch(event: GestureResponderEvent, touchId: TouchId): {pageX: number; pageY: number} | null {
  const native = event.nativeEvent;
  if (native.identifier === touchId) {
    return native;
  }
  return (
    native.touches?.find(touch => touch.identifier === touchId) ??
    native.changedTouches?.find(touch => touch.identifier === touchId) ??
    null
  );
}

function isTouchDown(event: GestureResponderEvent, touchId: TouchId): boolean {
  return !!event.nativeEvent.touches?.some(touch => touch.identifier === touchId);
}

const alwaysTrue = () => true;

export function StreamGrid({streams, layoutMode, onMove, renderCell}: Props) {
  const window = useWindowDimensions();
  const [viewportWidth, setViewportWidth] = useState(0);
  const containerWidth = viewportWidth > 0 ? viewportWidth : window.width;
  const layout = useMemo(
    () => computeGridLayout(streams.length, layoutMode, containerWidth),
    [containerWidth, layoutMode, streams.length],
  );
  const orderIds = useMemo(() => streams.map(stream => stream.id), [streams]);
  const orderKey = orderIds.join('\u001f');
  // 幅/表示モードが変わった時はアニメーションせず即座に合わせる(本数の増減は orderKey で検知)。
  const layoutKey = `${layoutMode}:${Math.round(containerWidth)}`;
  // 描画順は id 順で固定(並び替えでネイティブビューを動かさない)。
  const renderOrder = useMemo(
    () => streams.slice().sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)),
    [streams],
  );

  const [dragUI, setDragUI] = useState<{id: string; targetIndex: number} | null>(null);
  const [settlingId, setSettlingId] = useState<string | null>(null);

  const scrollRef = useRef<ScrollView>(null);
  const viewportRef = useRef<View>(null);
  const viewportMetricsRef = useRef({pageY: 0, height: 0});
  const scrollYRef = useRef(0);
  const valuesRef = useRef(new Map<string, CellValues>());
  const dragRef = useRef<DragSession | null>(null);
  const pendingRef = useRef<PendingLongPress | null>(null);
  const touchKindRef = useRef<'handle' | 'control' | null>(null);
  const rafRef = useRef<number | null>(null);
  const settlingIdRef = useRef<string | null>(null);
  const settledLayoutKeyRef = useRef<string | null>(null);

  // ハンドラは安定させたいので、最新の props/計算値は ref 経由で読む。
  const latestRef = useRef({layout, orderIds, orderKey, layoutKey, onMove});
  latestRef.current = {layout, orderIds, orderKey, layoutKey, onMove};

  const valuesFor = useCallback((id: string, frame: SlotFrame | undefined): CellValues => {
    let values = valuesRef.current.get(id);
    if (!values) {
      const initial = frame ?? {x: 0, y: 0, width: 0, height: 0};
      values = {
        x: new Animated.Value(initial.x),
        y: new Animated.Value(initial.y),
        scale: new Animated.Value(1),
        target: frame ? {x: frame.x, y: frame.y, scale: 1} : null,
        width: initial.width,
        height: initial.height,
      };
      valuesRef.current.set(id, values);
    }
    return values;
  }, []);

  const animateCell = useCallback(
    (values: CellValues, target: CellTarget, duration: number, onDone?: () => void) => {
      values.target = target;
      const config = {duration, easing: Easing.out(Easing.cubic), useNativeDriver: true};
      // parallel は stopTogether で他の値まで止めてしまうので個別に開始する。
      Animated.timing(values.x, {...config, toValue: target.x}).start(onDone ? () => onDone() : undefined);
      Animated.timing(values.y, {...config, toValue: target.y}).start();
      Animated.timing(values.scale, {...config, toValue: target.scale}).start();
    },
    [],
  );

  const setCell = useCallback((values: CellValues, target: CellTarget) => {
    values.target = target;
    values.x.setValue(target.x);
    values.y.setValue(target.y);
    values.scale.setValue(target.scale);
  }, []);

  const stopAutoScroll = useCallback(() => {
    if (rafRef.current != null) {
      cancelAnimationFrame(rafRef.current);
      rafRef.current = null;
    }
  }, []);

  const measureViewport = useCallback(() => {
    viewportRef.current?.measure?.((_x, _y, _width, height, _pageX, pageY) => {
      if (Number.isFinite(pageY) && Number.isFinite(height) && height > 0) {
        viewportMetricsRef.current = {pageY, height};
      }
    });
  }, []);

  // 他セルをプレビュー順の位置へ退かせる。ドラッグ中のセルは指に追従させる。
  const applyPreview = useCallback(
    (session: DragSession) => {
      const previewIds = moveItem(session.orderIds, session.fromIndex, session.targetIndex);
      previewIds.forEach((id, previewIndex) => {
        if (id === session.id) {
          return;
        }
        const committedIndex = session.orderIds.indexOf(id);
        const committed = session.frames[committedIndex];
        const target = session.frames[previewIndex];
        if (!committed || !target) {
          return;
        }
        const values = valuesFor(id, committed);
        const next = previewTransform(committed, target);
        if (!sameTarget(values.target, next)) {
          animateCell(values, next, shiftDurationMs);
        }
      });
    },
    [animateCell, valuesFor],
  );

  const updateDraggedCell = useCallback(
    (session: DragSession) => {
      const values = valuesRef.current.get(session.id);
      const committed = session.frames[session.fromIndex];
      if (!values || !committed) {
        return;
      }
      const x = committed.x + (session.pageX - session.startPageX);
      const y = committed.y + (session.pageY - session.startPageY) + (scrollYRef.current - session.startScrollY);
      values.x.setValue(x);
      values.y.setValue(y);
      const targetIndex = slotIndexAtPoint(session.frames, x + committed.width / 2, y + committed.height / 2);
      if (targetIndex >= 0 && targetIndex !== session.targetIndex) {
        session.targetIndex = targetIndex;
        applyPreview(session);
        setDragUI({id: session.id, targetIndex});
      }
    },
    [applyPreview],
  );

  const autoScrollTick = useCallback(() => {
    rafRef.current = null;
    const session = dragRef.current;
    if (!session) {
      return;
    }
    const metrics = viewportMetricsRef.current;
    if (metrics.height > 0) {
      const fingerY = session.pageY - metrics.pageY;
      const edge = Math.min(96, metrics.height * 0.2);
      let step = autoScrollStep(fingerY, metrics.height, edge, autoScrollMaxStep);
      // 画面端付近のセルを掴んだ瞬間に勝手にスクロールしないよう、その端へ向かって
      // 指を動かした時だけ自動スクロールする。
      const movedY = session.pageY - session.startPageY;
      if ((step > 0 && movedY < autoScrollArmDistance) || (step < 0 && movedY > -autoScrollArmDistance)) {
        step = 0;
      }
      if (step !== 0) {
        const maxScroll = Math.max(0, latestRef.current.layout.contentHeight - metrics.height);
        const next = Math.max(0, Math.min(maxScroll, scrollYRef.current + step));
        if (next !== scrollYRef.current) {
          scrollYRef.current = next;
          scrollRef.current?.scrollTo({x: 0, y: next, animated: false});
          updateDraggedCell(session);
        }
      }
    }
    rafRef.current = requestAnimationFrame(autoScrollTick);
  }, [updateDraggedCell]);

  const cancelPending = useCallback(() => {
    const pending = pendingRef.current;
    if (pending) {
      clearTimeout(pending.timer);
      pendingRef.current = null;
    }
  }, []);

  const beginDrag = useCallback(
    (id: string, touchId: TouchId, pageX: number, pageY: number, mode: DragSession['mode']) => {
      const {layout: currentLayout, orderIds: currentOrder, orderKey: currentOrderKey, layoutKey: currentLayoutKey} =
        latestRef.current;
      if (dragRef.current || currentOrder.length < 2) {
        return;
      }
      const fromIndex = currentOrder.indexOf(id);
      const frame = currentLayout.frames[fromIndex];
      if (fromIndex < 0 || !frame || frame.width <= 0) {
        return;
      }
      cancelPending();
      const session: DragSession = {
        id,
        touchId,
        mode,
        fromIndex,
        targetIndex: fromIndex,
        orderIds: currentOrder.slice(),
        frames: currentLayout.frames,
        layoutKey: currentLayoutKey,
        orderKey: currentOrderKey,
        startPageX: pageX,
        startPageY: pageY,
        startScrollY: scrollYRef.current,
        pageX,
        pageY,
      };
      dragRef.current = session;
      measureViewport();
      const values = valuesFor(id, frame);
      values.target = null;
      values.x.stopAnimation();
      values.y.stopAnimation();
      // scale をネイティブドライバで動かすと transform 全体がネイティブ側へ移り、
      // 以後の setValue(指追従)は React を経由せず UI スレッドへ直接届く。
      Animated.spring(values.scale, {toValue: liftScale, speed: 28, bounciness: 6, useNativeDriver: true}).start();
      updateDraggedCell(session);
      setDragUI({id, targetIndex: fromIndex});
      stopAutoScroll();
      rafRef.current = requestAnimationFrame(autoScrollTick);
    },
    [autoScrollTick, cancelPending, measureViewport, stopAutoScroll, updateDraggedCell, valuesFor],
  );

  const endDrag = useCallback(
    (commit: boolean) => {
      const session = dragRef.current;
      if (!session) {
        return;
      }
      dragRef.current = null;
      stopAutoScroll();
      const values = valuesRef.current.get(session.id);
      if (values) {
        // 指の位置から最終スロットへ戻す(settle で必ずアニメーションさせる)。
        values.target = null;
      }
      settlingIdRef.current = session.id;
      setSettlingId(session.id);
      setDragUI(null);
      const {orderKey: currentOrderKey} = latestRef.current;
      if (commit && session.targetIndex !== session.fromIndex && currentOrderKey === session.orderKey) {
        latestRef.current.onMove(session.id, session.targetIndex);
      }
    },
    [stopAutoScroll],
  );

  const touchTargets = useMemo<ReorderTouchTargets>(
    () => ({
      markHandleTouch: () => {
        touchKindRef.current = 'handle';
      },
      markControlTouch: () => {
        if (touchKindRef.current !== 'handle') {
          touchKindRef.current = 'control';
        }
      },
    }),
    [],
  );

  const handlers = useMemo(
    () => ({
      touchStart: (id: string, event: GestureResponderEvent) => {
        const kind = touchKindRef.current;
        touchKindRef.current = null;
        const native = event.nativeEvent;
        if ((native.touches?.length ?? 1) > 1) {
          // 2本目以降の指はドラッグを始めない。長押し待ち(ピンチ等)は取り消す。
          cancelPending();
          return;
        }
        // 指1本の新しいジェスチャー。前のジェスチャーの終了を取りこぼして状態が残って
        // いても(スクロール禁止のまま固まらないよう)ここで必ず片付ける。
        if (dragRef.current) {
          endDrag(false);
        }
        cancelPending();
        if (kind === 'handle') {
          beginDrag(id, native.identifier, native.pageX, native.pageY, 'handle');
          return;
        }
        if (kind === 'control' || latestRef.current.orderIds.length < 2) {
          return;
        }
        const next: PendingLongPress = {
          id,
          touchId: native.identifier,
          startPageX: native.pageX,
          startPageY: native.pageY,
          pageX: native.pageX,
          pageY: native.pageY,
          timer: setTimeout(() => {
            if (pendingRef.current !== next) {
              return;
            }
            pendingRef.current = null;
            beginDrag(next.id, next.touchId, next.pageX, next.pageY, 'longpress');
          }, longPressMs),
        };
        pendingRef.current = next;
      },
      touchMove: (id: string, event: GestureResponderEvent) => {
        const session = dragRef.current;
        if (session) {
          if (session.id !== id) {
            return;
          }
          const touch = findTouch(event, session.touchId);
          if (touch) {
            session.pageX = touch.pageX;
            session.pageY = touch.pageY;
            updateDraggedCell(session);
          }
          return;
        }
        const pending = pendingRef.current;
        if (!pending || pending.id !== id) {
          return;
        }
        const touch = findTouch(event, pending.touchId);
        if (!touch) {
          return;
        }
        pending.pageX = touch.pageX;
        pending.pageY = touch.pageY;
        if (Math.hypot(touch.pageX - pending.startPageX, touch.pageY - pending.startPageY) > longPressSlop) {
          cancelPending();
        }
      },
      touchEnd: (id: string, event: GestureResponderEvent) => {
        const session = dragRef.current;
        if (session) {
          if (session.id === id && !isTouchDown(event, session.touchId)) {
            endDrag(true);
          }
          return;
        }
        const pending = pendingRef.current;
        if (pending && pending.id === id && !isTouchDown(event, pending.touchId)) {
          cancelPending();
        }
      },
      touchCancel: (id: string) => {
        if (dragRef.current?.id === id) {
          endDrag(false);
        }
        if (pendingRef.current?.id === id) {
          cancelPending();
        }
      },
      // 長押しで開始したドラッグは、次の move で外枠が JS レスポンダーになり
      // (grant=true でネイティブのスクロール横取りを禁止)、以後は手放さない。
      wantsResponder: (id: string) => dragRef.current?.id === id && dragRef.current.mode === 'longpress',
      allowsTermination: (id: string) => dragRef.current?.id !== id,
      responderEnd: (id: string, commit: boolean) => {
        if (dragRef.current?.id === id) {
          endDrag(commit);
        }
      },
    }),
    [beginDrag, cancelPending, endDrag, updateDraggedCell],
  );

  // ドラッグしていない時は、確定順のスロットへ各セルを収める。追加/削除/並び替え確定は
  // アニメーション、幅やレイアウト(スタック⇔グリッド)の変化は即座に合わせる。
  useLayoutEffect(() => {
    const session = dragRef.current;
    if (session) {
      if (session.layoutKey !== layoutKey || session.orderKey !== orderKey) {
        // ドラッグ中に回転/追加/削除などが起きたら、その並び替えは取り消す。
        endDrag(false);
      }
      return;
    }
    const animateAllowed = settledLayoutKeyRef.current === layoutKey;
    settledLayoutKeyRef.current = layoutKey;
    const alive = new Set(orderIds);
    orderIds.forEach((id, index) => {
      const frame = layout.frames[index];
      if (!frame) {
        return;
      }
      const values = valuesFor(id, frame);
      const sizeChanged = Math.abs(values.width - frame.width) > 0.5 || Math.abs(values.height - frame.height) > 0.5;
      values.width = frame.width;
      values.height = frame.height;
      const target = {x: frame.x, y: frame.y, scale: 1};
      if (sameTarget(values.target, target)) {
        return;
      }
      const isSettling = settlingIdRef.current === id;
      if (animateAllowed && (isSettling || !sizeChanged)) {
        animateCell(values, target, settleDurationMs, isSettling ? () => {
          if (settlingIdRef.current === id) {
            settlingIdRef.current = null;
            setSettlingId(null);
          }
        } : undefined);
      } else {
        setCell(values, target);
      }
    });
    valuesRef.current.forEach((_values, id) => {
      if (!alive.has(id)) {
        valuesRef.current.delete(id);
      }
    });
  }, [animateCell, dragUI, endDrag, layout, layoutKey, orderIds, orderKey, setCell, valuesFor]);

  // settle のアニメーション完了通知が来なかった場合の保険(持ち上げ表示を必ず戻す)。
  useEffect(() => {
    if (!settlingId) {
      return;
    }
    const timer = setTimeout(() => {
      if (settlingIdRef.current === settlingId) {
        settlingIdRef.current = null;
      }
      setSettlingId(current => (current === settlingId ? null : current));
    }, settleDurationMs + 400);
    return () => clearTimeout(timer);
  }, [settlingId]);

  useEffect(
    () => () => {
      stopAutoScroll();
      cancelPending();
      dragRef.current = null;
    },
    [cancelPending, stopAutoScroll],
  );

  const onViewportLayout = useCallback(
    (event: LayoutChangeEvent) => {
      const {width, height} = event.nativeEvent.layout;
      setViewportWidth(current => (Math.abs(current - width) > 0.5 ? width : current));
      viewportMetricsRef.current = {...viewportMetricsRef.current, height};
      measureViewport();
    },
    [measureViewport],
  );

  const onScroll = useCallback((event: NativeSyntheticEvent<NativeScrollEvent>) => {
    // 自動スクロール中は自前の値を正とする(遅れて届くイベントで巻き戻さない)。
    if (!dragRef.current) {
      scrollYRef.current = event.nativeEvent.contentOffset.y;
    }
  }, []);

  const placeholderFrame = dragUI ? layout.frames[dragUI.targetIndex] : undefined;
  const contentStyle = useMemo(() => ({height: layout.contentHeight}), [layout.contentHeight]);

  return (
    <View ref={viewportRef} style={styles.viewport} onLayout={onViewportLayout}>
      <ScrollView
        ref={scrollRef}
        style={styles.viewport}
        contentContainerStyle={contentStyle}
        scrollEnabled={!dragUI}
        onScroll={onScroll}
        scrollEventThrottle={16}
        keyboardShouldPersistTaps="handled">
        {renderOrder.map(stream => {
          const index = orderIds.indexOf(stream.id);
          const frame = layout.frames[index];
          if (!frame) {
            return null;
          }
          // ドラッグ中は並び順を確定させないので、各セルの大きさは確定順のスロットのまま
          // (掴んだセルは同じ大きさで指に追従し、他セルは scale でプレビュー位置に収める)。
          return (
            <GridCell
              key={stream.id}
              stream={stream}
              width={frame.width}
              height={frame.height}
              values={valuesFor(stream.id, frame)}
              lifted={dragUI?.id === stream.id || settlingId === stream.id}
              handlers={handlers}
              touchTargets={touchTargets}
              renderCell={renderCell}
            />
          );
        })}
        {/* 落下位置の枠。子要素の末尾に足して既存セルの並びをずらさず、zIndex で背面に描く。 */}
        {placeholderFrame && (
          <View
            pointerEvents="none"
            style={[
              styles.placeholder,
              {
                left: placeholderFrame.x + gridCellGutter,
                top: placeholderFrame.y + gridCellGutter,
                width: Math.max(0, placeholderFrame.width - gridCellGutter * 2),
                height: Math.max(0, placeholderFrame.height - gridCellGutter * 2),
              },
            ]}
          />
        )}
      </ScrollView>
    </View>
  );
}

type GridCellHandlers = {
  touchStart: (id: string, event: GestureResponderEvent) => void;
  touchMove: (id: string, event: GestureResponderEvent) => void;
  touchEnd: (id: string, event: GestureResponderEvent) => void;
  touchCancel: (id: string) => void;
  wantsResponder: (id: string) => boolean;
  allowsTermination: (id: string) => boolean;
  responderEnd: (id: string, commit: boolean) => void;
};

const GridCell = memo(function GridCell({
  stream,
  width,
  height,
  values,
  lifted,
  handlers,
  touchTargets,
  renderCell,
}: {
  stream: StreamItem;
  width: number;
  height: number;
  values: CellValues;
  lifted: boolean;
  handlers: GridCellHandlers;
  touchTargets: ReorderTouchTargets;
  renderCell: Props['renderCell'];
}) {
  const id = stream.id;
  return (
    <Animated.View
      style={[
        styles.cell,
        lifted && styles.cellLifted,
        {
          width,
          height,
          transform: [{translateX: values.x}, {translateY: values.y}, {scale: values.scale}],
        },
      ]}
      onTouchStart={event => handlers.touchStart(id, event)}
      onTouchMove={event => handlers.touchMove(id, event)}
      onTouchEnd={event => handlers.touchEnd(id, event)}
      onTouchCancel={() => handlers.touchCancel(id)}
      onMoveShouldSetResponderCapture={() => handlers.wantsResponder(id)}
      onResponderGrant={alwaysTrue}
      onResponderTerminationRequest={() => handlers.allowsTermination(id)}
      onResponderRelease={() => handlers.responderEnd(id, true)}
      onResponderTerminate={() => handlers.responderEnd(id, false)}>
      {renderCell(stream, touchTargets)}
      {lifted && <View pointerEvents="none" style={styles.liftRing} />}
    </Animated.View>
  );
});

const styles = StyleSheet.create({
  viewport: {
    flex: 1,
  },
  cell: {
    position: 'absolute',
    left: 0,
    top: 0,
    padding: gridCellGutter,
  },
  cellLifted: {
    zIndex: 10,
    elevation: 12,
  },
  liftRing: {
    position: 'absolute',
    top: gridCellGutter - 1,
    right: gridCellGutter - 1,
    bottom: gridCellGutter - 1,
    left: gridCellGutter - 1,
    borderRadius: 19,
    borderWidth: 2,
    borderColor: 'rgba(103,168,255,0.95)',
  },
  placeholder: {
    position: 'absolute',
    zIndex: -1,
    borderRadius: 18,
    borderWidth: 1.5,
    borderColor: 'rgba(103,168,255,0.75)',
    backgroundColor: 'rgba(47,140,255,0.12)',
  },
});
