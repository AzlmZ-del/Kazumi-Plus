package com.example.kazumi

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** 只管理共享非 VPN 网关；请求与响应由 Dart 的 Dio 处理。 */
class DirectHttpHandler(context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "com.predidit.kazumi/direct_http"
    }

    private val appContext = context.applicationContext
    private val gateway = DirectProxyServer(appContext)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "isVpnActive" -> {
                    val manager = appContext.getSystemService(Context.CONNECTIVITY_SERVICE)
                        as? ConnectivityManager ?: error("ConnectivityManager 不可用")
                    result.success(manager.allNetworks.any { network ->
                        manager.getNetworkCapabilities(network)
                            ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
                    })
                }
                "startLocalProxy" -> gateway.start(result)
                "stopLocalProxy" -> gateway.stop(result)
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("DIRECT_GATEWAY", error.message ?: error.toString(), null)
        }
    }
}
