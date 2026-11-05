package com.example.kazumi

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.net.HttpURLConnection
import java.net.URL

/**
 * 绕过 VPN / TUN 的直连请求通道（规则级「直连」开关的 Android 实现）。
 *
 * 背景：Android 上的 Clash 之类是 TUN 型 VPN，内核按 uid 把包塞进 tun0，
 * Dart 的 HttpClient.findProxy 完全无效。唯一能从 App 侧绕开的办法是用
 * ConnectivityManager.requestNetwork() 申请一个明确排除 VPN 的网络，
 * 再在该 Network 上 openConnection()，流量直接走物理网卡。
 *
 * 只在规则的 directConnection 打开时使用；其余请求照旧走 Dio。
 */
class DirectHttpHandler(private val context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "com.predidit.kazumi/direct_http"

        /// 单次请求的网络申请超时：拿不到非 VPN 网络就立刻报错，不干等。
        private const val NETWORK_TIMEOUT_MS = 8000L
        private const val CONNECT_TIMEOUT_MS = 15000
        private const val READ_TIMEOUT_MS = 30000
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "request" -> request(call, result)
            "isVpnActive" -> result.success(isVpnActive())
            else -> result.notImplemented()
        }
    }

    /** 当前是否有 VPN 网络正在接管流量（决定要不要走原生直连）。 */
    private fun isVpnActive(): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return false
        return cm.allNetworks.any { network ->
            cm.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }
    }

    private fun request(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "url 不能为空", null)
            return
        }
        val method = call.argument<String>("method")?.uppercase() ?: "GET"
        val body = call.argument<String>("body")
        @Suppress("UNCHECKED_CAST")
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()

        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        if (cm == null) {
            result.error("NO_SERVICE", "ConnectivityManager 不可用", null)
            return
        }

        // 结果只能回一次：网络回调可能在超时后再到达。
        var replied = false
        fun replyOnce(error: String?, text: String?, message: String?) {
            if (replied) return
            replied = true
            if (error == null) result.success(text) else result.error(error, message, null)
        }

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                try {
                    val text = perform(network, url, method, body, headers)
                    cm.unregisterNetworkCallback(this)
                    replyOnce(null, text, null)
                } catch (e: Exception) {
                    cm.unregisterNetworkCallback(this)
                    replyOnce("DIRECT_FAIL", null, e.message ?: e.toString())
                }
            }

            override fun onUnavailable() {
                replyOnce(
                    "NO_NETWORK",
                    null,
                    "没有可用的非 VPN 网络（WiFi/移动数据都不可用）"
                )
            }
        }

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            // 关键：要求「不是 VPN」的能力位，系统才会给一块不经过 tun 的底层网络。
            // 注意 SDK 里没有 NET_CAPABILITY_VPN 这个常量，只有语义相反的
            // NET_CAPABILITY_NOT_VPN（API 21+），而且是 addCapability 而不是 remove。
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()

        try {
            // 带超时的 requestNetwork：超时会走 onUnavailable。
            cm.requestNetwork(request, callback, NETWORK_TIMEOUT_MS.toInt())
        } catch (e: Exception) {
            result.error("REQUEST_FAILED", e.message ?: e.toString(), null)
        }
    }

    /** 在指定 Network 上完成一次 HTTP 请求，返回响应正文。 */
    private fun perform(
        network: Network,
        url: String,
        method: String,
        body: String?,
        headers: Map<String, String>,
    ): String {
        val conn = network.openConnection(URL(url)) as HttpURLConnection
        try {
            conn.requestMethod = method
            conn.connectTimeout = CONNECT_TIMEOUT_MS
            conn.readTimeout = READ_TIMEOUT_MS
            conn.instanceFollowRedirects = true
            // openConnection 来自 network 本身，连接已绑定到这块非 VPN 网卡。
            headers.forEach { (key, value) -> conn.setRequestProperty(key, value) }
            if (body != null) {
                conn.doOutput = true
                conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.let { input ->
                BufferedReader(input.reader(Charsets.UTF_8)).use { it.readText() }
            } ?: ""
            if (code !in 200..299) {
                throw IllegalStateException("HTTP $code: ${text.take(200)}")
            }
            return text
        } finally {
            conn.disconnect()
        }
    }
}
