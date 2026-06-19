package com.multiview

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.modules.core.DeviceEventManagerModule

class NetworkInfoModule(private val reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext) {
  private val connectivityManager =
    reactContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
  private var callbackRegistered = false
  private var listenerCount = 0
  @Volatile private var trackedNetwork: Network? = null
  private val networkCallback = object : ConnectivityManager.NetworkCallback() {
    override fun onAvailable(network: Network) {
      trackedNetwork = network
      val capabilities = connectivityManager?.getNetworkCapabilities(network)
      emitConnectionType(capabilities?.let(::connectionType) ?: currentConnectionType())
    }

    override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
      trackedNetwork = network
      emitConnectionType(connectionType(networkCapabilities))
    }

    override fun onLost(network: Network) {
      if (trackedNetwork == network) {
        trackedNetwork = null
        emitCurrentConnectionType()
      }
    }
  }

  override fun getName(): String = "NetworkInfo"

  @ReactMethod
  fun getConnectionType(promise: Promise) {
    try {
      promise.resolve(currentConnectionType())
    } catch (_: Throwable) {
      promise.resolve("none")
    }
  }

  @ReactMethod
  fun addListener(eventName: String) {
    if (eventName != "networkChanged") {
      return
    }
    listenerCount += 1
    if (listenerCount == 1) {
      registerCallback()
    }
  }

  @ReactMethod
  fun removeListeners(count: Int) {
    listenerCount = (listenerCount - count).coerceAtLeast(0)
    if (listenerCount == 0) {
      unregisterCallback()
    }
  }

  override fun invalidate() {
    unregisterCallback()
    super.invalidate()
  }

  private fun currentConnectionType(): String {
    val manager = connectivityManager ?: return "none"
    val capabilities = manager.getNetworkCapabilities(manager.activeNetwork) ?: return "none"
    return connectionType(capabilities)
  }

  private fun connectionType(capabilities: NetworkCapabilities): String {
    return when {
      capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "wifi"
      capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
      else -> "other"
    }
  }

  private fun emitConnectionType(type: String) {
    try {
      reactContext
        .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
        .emit("networkChanged", type)
    } catch (_: Throwable) {
    }
  }

  private fun emitCurrentConnectionType() {
    emitConnectionType(currentConnectionType())
  }

  private fun registerCallback() {
    if (callbackRegistered) {
      return
    }
    try {
      connectivityManager?.registerDefaultNetworkCallback(networkCallback)
      callbackRegistered = connectivityManager != null
    } catch (_: Throwable) {
      callbackRegistered = false
    }
  }

  private fun unregisterCallback() {
    if (!callbackRegistered) {
      return
    }
    try {
      connectivityManager?.unregisterNetworkCallback(networkCallback)
    } catch (_: Throwable) {
    } finally {
      callbackRegistered = false
      trackedNetwork = null
    }
  }
}
