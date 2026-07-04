package com.multiview

import android.content.Context
import android.net.Uri
import com.facebook.drawee.backends.pipeline.Fresco
import com.facebook.drawee.drawable.ScalingUtils
import com.facebook.drawee.generic.GenericDraweeHierarchyBuilder
import com.facebook.drawee.view.SimpleDraweeView
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.annotations.ReactProp

class AnimatedImageView(context: Context) : SimpleDraweeView(context) {
  init {
    hierarchy = GenericDraweeHierarchyBuilder(resources)
      .setActualImageScaleType(ScalingUtils.ScaleType.FIT_CENTER)
      .build()
  }

  fun setSourceUrl(url: String?) {
    if (url.isNullOrBlank()) {
      controller = null
      return
    }
    controller = Fresco.newDraweeControllerBuilder()
      .setUri(Uri.parse(url))
      .setAutoPlayAnimations(true)
      .setOldController(controller)
      .build()
  }
}

class AnimatedImageManager : SimpleViewManager<AnimatedImageView>() {
  override fun getName(): String = "MVAnimatedImage"

  override fun createViewInstance(reactContext: ThemedReactContext): AnimatedImageView =
    AnimatedImageView(reactContext)

  @ReactProp(name = "sourceUrl")
  fun setSourceUrl(view: AnimatedImageView, sourceUrl: String?) {
    view.setSourceUrl(sourceUrl)
  }
}
