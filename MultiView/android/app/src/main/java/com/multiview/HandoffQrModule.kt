package com.multiview

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.util.Base64
import com.facebook.react.bridge.ActivityEventListener
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.integration.android.IntentIntegrator
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import java.io.ByteArrayOutputStream

// iOS Handoff.swift の HandoffQR(生成) / HandoffScannerController(読み取り) に相当。
// 生成は zxing core、読み取りは zxing-android-embedded の CaptureActivity(カメラ権限の
// ランタイム要求も自前処理)を使い、結果は Promise で JS へ返す。
class HandoffQrModule(private val reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext), ActivityEventListener {

  private var pendingScan: Promise? = null

  init {
    reactContext.addActivityEventListener(this)
  }

  override fun getName(): String = "HandoffQr"

  // iOS HandoffQR.image(correctionLevel="M")と同じ誤り訂正レベルで PNG(base64) を返す。
  @ReactMethod
  fun encode(text: String, size: Int, promise: Promise) {
    try {
      val side = size.coerceIn(64, 2048)
      val hints = mapOf(
        EncodeHintType.CHARACTER_SET to "UTF-8",
        EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M,
        EncodeHintType.MARGIN to 2,
      )
      val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, side, side, hints)
      val pixels = IntArray(side * side)
      for (y in 0 until side) {
        val offset = y * side
        for (x in 0 until side) {
          pixels[offset + x] = if (matrix.get(x, y)) Color.BLACK else Color.WHITE
        }
      }
      val bitmap = Bitmap.createBitmap(pixels, side, side, Bitmap.Config.ARGB_8888)
      val output = ByteArrayOutputStream()
      bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
      bitmap.recycle()
      promise.resolve(Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP))
    } catch (error: Exception) {
      promise.reject("qr_encode_failed", error)
    }
  }

  @ReactMethod
  fun scan(promise: Promise) {
    val activity = reactContext.currentActivity
    if (activity == null) {
      promise.reject("qr_no_activity", "アクティビティを取得できませんでした")
      return
    }
    if (pendingScan != null) {
      promise.reject("qr_scan_in_progress", "QRスキャンは既に実行中です")
      return
    }
    pendingScan = promise
    try {
      IntentIntegrator(activity)
        .setDesiredBarcodeFormats(IntentIntegrator.QR_CODE)
        .setPrompt("送る側のQRを枠に合わせてください")
        .setBeepEnabled(false)
        .setOrientationLocked(true)
        .initiateScan()
    } catch (error: Exception) {
      pendingScan = null
      promise.reject("qr_scan_failed", error)
    }
  }

  override fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?) {
    if (requestCode != IntentIntegrator.REQUEST_CODE) {
      return
    }
    val promise = pendingScan ?: return
    pendingScan = null
    val result = IntentIntegrator.parseActivityResult(requestCode, resultCode, data)
    val contents = result?.contents
    if (contents.isNullOrEmpty()) {
      // キャンセル(カメラ拒否含む)。JS側は静かに無視できるよう専用コードで返す。
      promise.reject("qr_scan_cancelled", "スキャンをキャンセルしました")
    } else {
      promise.resolve(contents)
    }
  }

  override fun onNewIntent(intent: Intent) = Unit

  override fun invalidate() {
    reactContext.removeActivityEventListener(this)
    // 破棄時にスキャン中の Promise を握りつぶすと JS 側の await が永久に解決しない。
    // キャンセル扱いで reject してから捨てる。
    pendingScan?.reject("qr_scan_cancelled", "スキャンを中断しました")
    pendingScan = null
    super.invalidate()
  }
}
