import {appSafeAreaEdges, focusedPaneLayout, isWideFocusedLayout} from '../layout';

describe('adaptive app layout', () => {
  it('protects every edge for cutouts, system bars, and multi-window', () => {
    expect(appSafeAreaEdges).toEqual(['top', 'right', 'bottom', 'left']);
  });

  it.each([
    [411, 960, false], // Z Fold cover display, portrait
    [750, 832, false], // Z Fold inner display, portrait
    [960, 411, true], // cover display, landscape
    [750, 500, true], // short multi-window
  ])('selects the focused layout for a %sx%s window', (width, height, expected) => {
    expect(isWideFocusedLayout(width, height)).toBe(expected);
  });

  it('does not select a layout before valid window metrics arrive', () => {
    expect(isWideFocusedLayout(0, 0)).toBe(false);
  });

  it.each([
    [411, 960, true, 'stacked'],
    [960, 411, true, 'wide'],
    [411, 960, false, 'solo'],
    [960, 411, false, 'solo'],
  ])(
    '%sx%s with chat=%s uses the %s focused layout',
    (width, height, showChat, expected) => {
      expect(focusedPaneLayout(width as number, height as number, showChat as boolean)).toBe(
        expected,
      );
    },
  );
});
