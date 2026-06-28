import type {Edge} from 'react-native-safe-area-context';

// Android 15+ lays the app edge-to-edge. Keep every interactive surface clear of
// status/navigation bars and display cutouts, including Fold cover-screen cutouts.
export const appSafeAreaEdges: Edge[] = ['top', 'right', 'bottom', 'left'];

// A vertical focused layout cannot fit its 16:9 player on a short landscape or
// split-screen window. Keep the chat-first composition, but place it side by side.
export function isWideFocusedLayout(width: number, height: number): boolean {
  return width > 0 && height > 0 && width > height * 1.2;
}

export type FocusedPaneLayout = 'solo' | 'stacked' | 'wide';

export function focusedPaneLayout(
  width: number,
  height: number,
  showChat: boolean,
): FocusedPaneLayout {
  if (!showChat) {
    return 'solo';
  }
  return isWideFocusedLayout(width, height) ? 'wide' : 'stacked';
}
