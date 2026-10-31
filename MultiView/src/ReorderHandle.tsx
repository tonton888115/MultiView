import type React from 'react';
import {UIManager, View, requireNativeComponent, type ViewProps} from 'react-native';

// 並び替えハンドルの土台。ネイティブ側の MultiViewReorderHandle(ReorderHandleViewManager.kt)
// は触れた瞬間に ScrollView のタッチ横取りを止める。ネイティブを再ビルドしていない APK
// (Metro で JS だけ更新した場合など)では未登録なので、通常の View にフォールバックする。
const nativeHandleName = 'MultiViewReorderHandle';

function resolveReorderHandleBase(): React.ComponentType<ViewProps> {
  try {
    if (UIManager.hasViewManagerConfig?.(nativeHandleName)) {
      return requireNativeComponent<ViewProps>(nativeHandleName) as unknown as React.ComponentType<ViewProps>;
    }
  } catch {
    // 取得できなければ通常の View で動かす。
  }
  return View;
}

export const ReorderHandleBase = resolveReorderHandleBase();
