// 視聴タブのセル配置(スタック/グリッド)とドラッグ並び替えの純粋計算。
//
// セルは「描画順を固定したまま、位置だけ transform で動かす」方式で並べる(StreamGrid.tsx)。
// React の子要素の順番を入れ替えると Fabric がネイティブビューを外して付け直し、
// TextureView(ExoPlayer)の Surface 再生成や WebView の再アタッチで映像が黒く瞬くため、
// 並び順はここで計算した各スロットの座標へ移動させるだけにする。

import type {LayoutMode} from './types';

export type SlotFrame = {
  x: number;
  y: number;
  width: number;
  height: number;
};

export type GridLayout = {
  frames: SlotFrame[];
  contentHeight: number;
};

// ScrollView の内側余白(上/左右)と下余白、各セル外周のすき間。従来の
// streamGrid(padding 8 / paddingBottom 18) と streamCellWrap(padding 6) と同値。
export const gridContentPadding = 8;
export const gridContentPaddingBottom = 18;
export const gridCellGutter = 6;

const playerAspect = 9 / 16;

// スロット(すき間込み)の幅から高さを求める。中のセルは 16:9。
export function slotHeightForWidth(width: number): number {
  const inner = Math.max(0, width - gridCellGutter * 2);
  return Math.round(inner * playerAspect + gridCellGutter * 2);
}

// iOS ViewingController.addGrid と同じ規則: グリッドは2列で詰め、奇数本のときだけ
// 最後の1本を全幅にする。スタックは全幅で縦に並べる。
export function computeGridLayout(count: number, layoutMode: LayoutMode, containerWidth: number): GridLayout {
  const innerWidth = Math.max(0, containerWidth - gridContentPadding * 2);
  const frames: SlotFrame[] = [];
  let y = gridContentPadding;
  if (layoutMode === 'grid') {
    const halfWidth = innerWidth / 2;
    const halfHeight = slotHeightForWidth(halfWidth);
    const pairedCount = count - (count % 2);
    for (let index = 0; index < pairedCount; index += 1) {
      const column = index % 2;
      frames.push({x: gridContentPadding + column * halfWidth, y, width: halfWidth, height: halfHeight});
      if (column === 1) {
        y += halfHeight;
      }
    }
    if (count % 2 === 1) {
      const fullHeight = slotHeightForWidth(innerWidth);
      frames.push({x: gridContentPadding, y, width: innerWidth, height: fullHeight});
      y += fullHeight;
    }
  } else {
    const fullHeight = slotHeightForWidth(innerWidth);
    for (let index = 0; index < count; index += 1) {
      frames.push({x: gridContentPadding, y, width: innerWidth, height: fullHeight});
      y += fullHeight;
    }
  }
  return {frames, contentHeight: y + gridContentPaddingBottom};
}

// 点(ドラッグ中セルの中心)が入るスロット。どのスロットにも入らない(すき間/外側)
// 場合は中心が最も近いスロットを返す。スロット枠は並び順に依存しないので、
// 判定結果は指の位置だけで決まり、プレビュー移動による振動(行ったり来たり)が起きない。
export function slotIndexAtPoint(frames: SlotFrame[], x: number, y: number): number {
  let nearest = -1;
  let nearestDistance = Number.POSITIVE_INFINITY;
  for (let index = 0; index < frames.length; index += 1) {
    const frame = frames[index];
    if (x >= frame.x && x < frame.x + frame.width && y >= frame.y && y < frame.y + frame.height) {
      return index;
    }
    const dx = x - (frame.x + frame.width / 2);
    const dy = y - (frame.y + frame.height / 2);
    const distance = dx * dx + dy * dy;
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearest = index;
    }
  }
  return nearest;
}

export function moveItem<T>(items: readonly T[], from: number, to: number): T[] {
  const next = items.slice();
  if (from < 0 || from >= next.length) {
    return next;
  }
  const target = Math.max(0, Math.min(to, next.length - 1));
  if (target === from) {
    return next;
  }
  const [item] = next.splice(from, 1);
  next.splice(target, 0, item);
  return next;
}

// 大きさの違うスロットへプレビュー移動するセルを、レイアウトを変えずに transform だけで
// 収める(iOS の gridTransform と同じ考え方)。scale は中心基準なので左上のずれを補正する。
export function previewTransform(
  committed: SlotFrame,
  target: SlotFrame,
): {x: number; y: number; scale: number} {
  if (committed.width <= 0 || committed.height <= 0) {
    return {x: target.x, y: target.y, scale: 1};
  }
  const scale = target.width / committed.width;
  return {
    x: target.x - (committed.width * (1 - scale)) / 2,
    y: target.y - (committed.height * (1 - scale)) / 2,
    scale,
  };
}

// 端に近づいたときの自動スクロール量(px/フレーム)。端からの距離に比例して速くする。
export function autoScrollStep(fingerY: number, viewportHeight: number, edge: number, maxStep: number): number {
  if (viewportHeight <= 0 || edge <= 0) {
    return 0;
  }
  if (fingerY < edge) {
    const depth = Math.min(1, (edge - fingerY) / edge);
    return -Math.max(1, Math.round(maxStep * depth));
  }
  if (fingerY > viewportHeight - edge) {
    const depth = Math.min(1, (fingerY - (viewportHeight - edge)) / edge);
    return Math.max(1, Math.round(maxStep * depth));
  }
  return 0;
}
