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
            "startLocalProxy" -> startLocalProxy(result)
            "stopLocalProxy" -> stopLocalProxy(result)
            else -> result.notImplemented()
        }
    }

    /**
     * 本地 CONNECT 隧道（mpv 专用直连出口）。
     *
     * mpv 以 http://127.0.0.1:<port> 为 http-proxy，发来的 CONNECT host:443
     * 在 NOT_VPN 网卡上建 TCP 隧道，字节原样双向转发；TLS 由 mpv 与源站端到端完成。
     * 与 PoC 的差别：单例 ServerSocket、可显式关闭、监听线程可退出。
     */
    private var proxyServer: java.net.ServerSocket? = null
    private var proxyCallback: ConnectivityManager.NetworkCallback? = null
    private var proxyCm: ConnectivityManager? = null

    /** 尚未回复的 startLocalProxy 调用；stop 时替它回一个错误，免 Dart 侧 await 挂死。 */
    private var pendingProxyStart: MethodChannel.Result? = null

    /**
     * 代际计数：每次 start 自增，每次 stop 也自增。
     *
     * requestNetwork 的回调可能在 unregister 之后才被投递，若不校验代际，
     * 一次已作废的 onAvailable 仍会建出 ServerSocket —— 那个 socket 没人持有，
     * 既关不掉也不会随 stop 释放，反而比原来的 callback 泄漏更难查。
     */
    private var proxyGeneration = 0
    private val proxyLock = Any()

    /**
     * 申请一次 NetworkCallback，获批后就地建隧道。
     *
     * 结果只回一次：超时后再到的网络回调不会二次 reply。
     */
    private fun requestProxyNetwork(
        cm: ConnectivityManager,
        request: NetworkRequest,
        result: MethodChannel.Result,
    ) {
        var replied = false
        val generation = synchronized(proxyLock) {
            proxyGeneration += 1
            pendingProxyStart = result
            proxyGeneration
        }

        fun replyOnce(error: String?, payload: Any?, message: String?) {
            synchronized(proxyLock) {
                if (replied) return
                replied = true
                if (pendingProxyStart === result) pendingProxyStart = null
            }
            if (error == null) result.success(payload)
            else result.error(error, message, null)
        }

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                var server: java.net.ServerSocket? = null
                var rejectReason: String? = null
                synchronized(proxyLock) {
                    // 代际不符 = 已被 stop 或已被新一轮 start 取代，本次回调作废。
                    if (generation != proxyGeneration || proxyCallback !== this) {
                        rejectReason = "隧道申请已作废"
                    } else {
                        try {
                            server = java.net.ServerSocket(
                                0, 50, java.net.InetAddress.getByName("127.0.0.1")
                            )
                            proxyServer = server
                        } catch (e: Exception) {
                            rejectReason = e.message ?: e.toString()
                        }
                    }
                }

                // 建 socket 之外的善后都放到锁外，避免持锁调用通道回复。
                val started = server
                if (started == null) {
                    replyOnce("PROXY_START_FAILED", null, rejectReason)
                    return
                }
                // 每个连接独立线程：CONNECT 握手后纯字节转发。
                Thread {
                    while (!started.isClosed) {
                        val client = try { started.accept() } catch (e: Exception) { break }
                        Thread {
                            try { handleConnect(client, network) }
                            catch (e: Exception) { try { client.close() } catch (_: Exception) {} }
                        }.start()
                    }
                }.start()
                replyOnce(null, started.localPort, null)
            }

            override fun onUnavailable() {
                // 带超时的 requestNetwork 在 onUnavailable 后由系统自行注销，
                // 这里只需摘掉引用，免得 stop 再对已注销的 callback 调 unregister。
                synchronized(proxyLock) {
                    if (proxyCallback === this) {
                        proxyCallback = null
                        proxyCm = null
                    }
                }
                replyOnce("NO_NETWORK", null, "没有可用的非 VPN 网络")
            }
        }

        synchronized(proxyLock) {
            proxyCallback = callback
            proxyCm = cm
        }

        try {
            cm.requestNetwork(request, callback, NETWORK_TIMEOUT_MS.toInt())
        } catch (e: Exception) {
            replyOnce("REQUEST_FAILED", null, e.message ?: e.toString())
        }
    }

    private fun startLocalProxy(result: MethodChannel.Result) {
        synchronized(proxyLock) {
            // 已有隧道在跑：直接复用，避免每次播放都新建。
            // 隧道常驻而非跟随播放器实例：切集/换源都会重建播放器，复用端口才不会每次都
            // 重新 requestNetwork（最长等 NETWORK_TIMEOUT_MS）。
            proxyServer?.let {
                result.success(it.localPort)
                return
            }
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: run {
                    result.error("NO_CM", "ConnectivityManager 不可用", null)
                    return
                }
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            requestProxyNetwork(cm, request, result)
        }
    }

    /**
     * 关闭本地隧道并注销网络回调。
     *
     * 只在 App 退出时调用一次：隧道本身是常驻单例（见 [startLocalProxy] 的复用分支）。
     * 早期版本漏了 unregisterNetworkCallback，每次进程内重启隧道都会残留一个回调，
     * 触碰系统对同进程回调数量的上限后 requestNetwork 会静默失败。
     */
    private fun stopLocalProxy(result: MethodChannel.Result) {
        val pending: MethodChannel.Result?
        synchronized(proxyLock) {
            proxyGeneration += 1
            proxyCallback?.let { callback ->
                try {
                    proxyCm?.unregisterNetworkCallback(callback)
                } catch (_: Exception) {
                    // 已被系统自行注销（如网络丢失）时会抛，忽略即可。
                }
            }
            proxyCallback = null
            proxyCm = null
            try {
                // close 让 accept() 抛异常，监听线程随之退出。
                proxyServer?.close()
            } catch (_: Exception) {}
            proxyServer = null
            pending = pendingProxyStart
            pendingProxyStart = null
        }
        // 启动申请还悬着就替它回错误，否则那侧的 await 会一直等到 Activity 销毁。
        try {
            pending?.error("PROXY_STOPPED", "隧道已关闭", null)
        } catch (_: Exception) {}
        result.success(null)
    }

    /** 处理单条连接：读 CONNECT 行，经 NOT_VPN 网卡连目标，之后双向转发。 */
    private fun handleConnect(client: java.net.Socket, network: Network) {
        client.soTimeout = 0
        val reader = client.getInputStream().bufferedReader()
        val firstLine = reader.readLine() ?: return
        // 形如 CONNECT host:port HTTP/1.1
        val target = firstLine.split(" ").getOrNull(1) ?: return
        // 把请求头读完丢弃（mpv 的 Proxy-Authorization 等，PoC 不校验）。
        while (reader.readLine()?.isNotEmpty() == true) { }
        val (host, port) = if (target.contains(":")) {
            target.split(":").let { it[0] to (it.getOrNull(1)?.toIntOrNull() ?: 443) }
        } else {
            target to 443
        }
        // network.socketFactory 造出的 socket 绑定在非 VPN 网卡上。
        val remote = network.socketFactory.createSocket(host, port)
        client.getOutputStream().write("HTTP/1.1 200 Connection Established\r\n\r\n".toByteArray())
        client.getOutputStream().flush()
        // 双向转发：client <-> remote。
        val t1 = Thread {
            try { client.getInputStream().copyTo(remote.getOutputStream()) } catch (_: Exception) {} finally { try { remote.shutdownOutput() } catch (_: Exception) {} }
        }
        val t2 = Thread {
            try { remote.getInputStream().copyTo(client.getOutputStream()) } catch (_: Exception) {} finally { try { client.close() } catch (_: Exception) {} }
        }
        t1.start(); t2.start(); t1.join(); t2.join()
        try { remote.close() } catch (_: Exception) {}
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
