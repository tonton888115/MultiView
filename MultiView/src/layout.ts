export interface GridShape {
  cols: number;
  rows: number;
}

// Pick a balanced grid, biased to more rows in portrait and more columns in landscape.
export function computeGrid(
  count: number,
  isLandscape: boolean,
  stacked = false,
): GridShape {
  if (count <= 0) {
    return { cols: 1, rows: 1 };
  }
  if (stacked) {
    return { cols: 1, rows: count };
  }
  let cols = Math.ceil(Math.sqrt(count));
  let rows = Math.ceil(count / cols);
  if (isLandscape && rows > cols) {
    [cols, rows] = [rows, cols];
  }
  if (!isLandscape && cols > rows) {
    [cols, rows] = [rows, cols];
  }
  return { cols, rows };
}
