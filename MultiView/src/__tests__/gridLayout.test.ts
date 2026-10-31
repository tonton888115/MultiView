import {
  autoScrollStep,
  computeGridLayout,
  gridCellGutter,
  gridContentPadding,
  gridContentPaddingBottom,
  moveItem,
  previewTransform,
  slotHeightForWidth,
  slotIndexAtPoint,
} from '../gridLayout';

describe('grid layout', () => {
  it('stacks full-width 16:9 slots', () => {
    const {frames, contentHeight} = computeGridLayout(3, 'stacked', 416);
    const width = 416 - gridContentPadding * 2;
    const height = slotHeightForWidth(width);
    expect(frames).toEqual([
      {x: gridContentPadding, y: gridContentPadding, width, height},
      {x: gridContentPadding, y: gridContentPadding + height, width, height},
      {x: gridContentPadding, y: gridContentPadding + height * 2, width, height},
    ]);
    expect(contentHeight).toBe(gridContentPadding + height * 3 + gridContentPaddingBottom);
    expect(height).toBe(Math.round((width - gridCellGutter * 2) * (9 / 16) + gridCellGutter * 2));
  });

  it('pairs grid slots and makes only the odd trailing slot full width (iOS addGrid parity)', () => {
    const even = computeGridLayout(4, 'grid', 416).frames;
    expect(even.map(frame => frame.width)).toEqual([200, 200, 200, 200]);
    expect(even[1].x).toBe(gridContentPadding + 200);
    expect(even[2].y).toBe(even[0].y + even[0].height);

    const odd = computeGridLayout(3, 'grid', 416).frames;
    expect(odd.map(frame => frame.width)).toEqual([200, 200, 400]);
    expect(odd[2].x).toBe(gridContentPadding);
    expect(odd[2].y).toBe(odd[0].y + odd[0].height);
  });

  it('handles empty and degenerate widths', () => {
    expect(computeGridLayout(0, 'grid', 400)).toEqual({
      frames: [],
      contentHeight: gridContentPadding + gridContentPaddingBottom,
    });
    const {frames} = computeGridLayout(1, 'stacked', 0);
    expect(frames[0].width).toBe(0);
    expect(frames[0].height).toBe(gridCellGutter * 2);
  });
});

describe('drag target resolution', () => {
  const {frames} = computeGridLayout(3, 'grid', 416);

  it('returns the slot containing the point', () => {
    expect(slotIndexAtPoint(frames, frames[1].x + 10, frames[1].y + 10)).toBe(1);
    expect(slotIndexAtPoint(frames, frames[2].x + frames[2].width - 5, frames[2].y + 5)).toBe(2);
  });

  it('falls back to the nearest slot outside every slot', () => {
    expect(slotIndexAtPoint(frames, -500, -500)).toBe(0);
    expect(slotIndexAtPoint(frames, 1000, -10)).toBe(1);
    expect(slotIndexAtPoint(frames, 200, 10000)).toBe(2);
    expect(slotIndexAtPoint([], 0, 0)).toBe(-1);
  });
});

describe('moveItem', () => {
  it('moves forward and backward and clamps', () => {
    expect(moveItem(['a', 'b', 'c', 'd'], 0, 2)).toEqual(['b', 'c', 'a', 'd']);
    expect(moveItem(['a', 'b', 'c', 'd'], 3, 0)).toEqual(['d', 'a', 'b', 'c']);
    expect(moveItem(['a', 'b', 'c'], 1, 99)).toEqual(['a', 'c', 'b']);
    expect(moveItem(['a', 'b', 'c'], 5, 0)).toEqual(['a', 'b', 'c']);
  });

  it('does not mutate the input', () => {
    const input = ['a', 'b', 'c'];
    moveItem(input, 0, 2);
    expect(input).toEqual(['a', 'b', 'c']);
  });
});

describe('previewTransform', () => {
  it('scales around the center so the cell lands exactly on the target slot', () => {
    const committed = {x: 8, y: 8, width: 400, height: 237};
    const target = {x: 208, y: 8, width: 200, height: 119};
    const {x, y, scale} = previewTransform(committed, target);
    expect(scale).toBeCloseTo(0.5);
    // 中心基準で縮めた後の左上 = x + w(1-s)/2
    expect(x + (committed.width * (1 - scale)) / 2).toBeCloseTo(target.x);
    expect(y + (committed.height * (1 - scale)) / 2).toBeCloseTo(target.y);
  });

  it('is a pure translation between equally sized slots', () => {
    expect(previewTransform({x: 8, y: 8, width: 200, height: 119}, {x: 208, y: 127, width: 200, height: 119})).toEqual({
      x: 208,
      y: 127,
      scale: 1,
    });
  });
});

describe('autoScrollStep', () => {
  it('scrolls only inside the edge zones, faster closer to the edge', () => {
    expect(autoScrollStep(300, 600, 80, 18)).toBe(0);
    expect(autoScrollStep(0, 600, 80, 18)).toBe(-18);
    expect(autoScrollStep(70, 600, 80, 18)).toBeLessThan(0);
    expect(autoScrollStep(70, 600, 80, 18)).toBeGreaterThan(-18);
    expect(autoScrollStep(600, 600, 80, 18)).toBe(18);
    expect(autoScrollStep(-100, 600, 80, 18)).toBe(-18);
    expect(autoScrollStep(100, 0, 80, 18)).toBe(0);
  });
});
