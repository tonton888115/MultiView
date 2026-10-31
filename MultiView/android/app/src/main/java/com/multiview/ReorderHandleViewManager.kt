package com.multiview

import android.content.Context
import android.view.MotionEvent
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.views.view.ReactViewGroup
import com.facebook.react.views.view.ReactViewManager

// 視聴タブの並び替えハンドル(≡)。通常の RN View と同じ見た目/props を持ちつつ、
// 指が触れた瞬間(ACTION_DOWN)に祖先の ScrollView へ「タッチを横取りしないで」と伝える。
// JS 側でスクロール停止やレスポンダー確保が反映されるまでの数フレームの間に縦へ動かすと、
// ScrollView がジェスチャーを奪ってドラッグがキャンセルされていたのを防ぐ。
class ReorderHandleViewManager : ReactViewManager() {
  override fun getName(): String = NAME

  override fun createViewInstance(context: ThemedReactContext): ReactViewGroup = ReorderHandleView(context)

  companion object {
    const val NAME = "MultiViewReorderHandle"
  }
}

class ReorderHandleView(context: Context) : ReactViewGroup(context) {
  override fun dispatchTouchEvent(event: MotionEvent): Boolean {
    if (event.actionMasked == MotionEvent.ACTION_DOWN) {
      parent?.requestDisallowInterceptTouchEvent(true)
    }
    return super.dispatchTouchEvent(event)
  }
}
