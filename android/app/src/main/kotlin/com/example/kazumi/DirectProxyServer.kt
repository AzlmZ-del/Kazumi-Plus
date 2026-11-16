package com.example.kazumi

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.Semaphore
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** 一个非 VPN 出口同时服务 Dio、WebView 和 mpv，不解密 TLS。 */
internal class DirectProxyServer(private val context: Context) {
    companion object {
        private const val NETWORK_TIMEOUT_MS = 8000L
        private const val IO_TIMEOUT_MS = 15000
        private const val MAX_CONNECTIONS = 64
    }

    private val lock = Any()
    private var cm: ConnectivityManager? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var listener: ServerSocket? = null
    private var currentNetwork: Network? = null
    private var generation = 0
    private var attempt: StartAttempt? = null
    private val tracked = ConcurrentHashMap.newKeySet<Socket>()
    private val slots = Semaphore(MAX_CONNECTIONS)
    private val workers = Executors.newCachedThreadPool { r ->
        Thread(r, "direct-proxy").apply { isDaemon = true }
    }
    // DNS 超时后系统解析不一定响应 interrupt，单独限流，避免无限增长线程。
    private val dns = ThreadPoolExecutor(4, 4, 0L, TimeUnit.MILLISECONDS,
        ArrayBlockingQueue<Runnable>(MAX_CONNECTIONS),
        { r -> Thread(r, "direct-proxy-dns").apply { isDaemon = true } })
    private val timers = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "direct-proxy-timeout").apply { isDaemon = true }
    }

    private class StartAttempt(val gen: Int) {
        val waiters = ArrayList<MethodChannel.Result>()
        var timeout: ScheduledFuture<*>? = null
    }

    fun start(result: MethodChannel.Result) {
        var error: Exception? = null
        var fresh: StartAttempt? = null
        synchronized(lock) {
            val running = listener
            if (running != null && !running.isClosed && currentNetwork != null) {
                result.success(running.localPort)
                return
            }
            attempt?.let { it.waiters.add(result); return }
            val manager = cm ?: context.getSystemService(Context.CONNECTIVITY_SERVICE)
                as? ConnectivityManager ?: run {
                    result.error("NO_CM", "ConnectivityManager 不可用", null)
                    return
                }
            val register = callback == null
            if (register) generation++
            val a = StartAttempt(generation)
            a.waiters.add(result)
            attempt = a
            fresh = a
            cm = manager
            // 申请和回调均受期限约束，不能让等待物理网络的调用悬空。
            a.timeout = timers.schedule({
                failAttempt(a, "NO_NETWORK", "没有可用的非 VPN 网络")
            }, NETWORK_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            if (register) {
                val cb = ProxyNetworkCallback(generation)
                callback = cb
                try {
                    manager.requestNetwork(NetworkRequest.Builder()
                        .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                        .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                        .build(), cb, NETWORK_TIMEOUT_MS.toInt())
                } catch (e: Exception) { error = e }
            }
        }
        error?.let { failAttempt(fresh!!, "REQUEST_FAILED", it.message) }
    }

    fun stop(result: MethodChannel.Result) {
        val waiters: List<MethodChannel.Result>
        synchronized(lock) {
            generation++
            val pending = attempt
            attempt = null
            pending?.timeout?.cancel(false)
            waiters = pending?.waiters?.toList() ?: emptyList()
            pending?.waiters?.clear()
            clearLocked()
        }
        waiters.forEach { replyError(it, "PROXY_STOPPED", "直连网关已关闭") }
        result.success(null)
    }

    private fun clearLocked() {
        callback?.let { cb -> try { cm?.unregisterNetworkCallback(cb) } catch (_: Exception) {} }
        callback = null
        cm = null
        currentNetwork = null
        closeQuietly(listener)
        listener = null
        tracked.forEach { closeQuietly(it) }
        tracked.clear()
    }

    private inner class ProxyNetworkCallback(val gen: Int) : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val caps = synchronized(lock) {
                if (gen != generation || callback !== this) return
                cm?.getNetworkCapabilities(network)
            }
            if (caps != null) adopt(network, this, gen, caps)
        }

        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
            adopt(network, this, gen, caps)

        override fun onLost(network: Network) {
            synchronized(lock) {
                if (gen != generation || callback !== this || currentNetwork != network) return
                currentNetwork = null
                tracked.forEach { closeQuietly(it) }
                tracked.clear()
            }
        }

        override fun onUnavailable() {
            val pending = synchronized(lock) {
                if (gen != generation || callback !== this) return
                // 系统已注销这次申请，不再重复 unregister。
                callback = null
                attempt
            }
            pending?.let { failAttempt(it, "NO_NETWORK", "没有可用的非 VPN 网络") }
        }
    }

    private fun adopt(network: Network, cb: ConnectivityManager.NetworkCallback,
        gen: Int, caps: NetworkCapabilities) {
        var pending: StartAttempt? = null
        var port: Int? = null
        var error: Exception? = null
        synchronized(lock) {
            if (gen != generation || callback !== cb) return
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) ||
                !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                if (currentNetwork == network) {
                    currentNetwork = null
                    tracked.forEach { closeQuietly(it) }
                    tracked.clear()
                }
                return
            }
            if (currentNetwork != null && currentNetwork != network) {
                tracked.forEach { closeQuietly(it) }
                tracked.clear()
            }
            currentNetwork = network
            try {
                var server = listener
                if (server == null || server.isClosed) {
                    server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
                    listener = server
                    val captured = server
                    Thread({ acceptLoop(captured) }, "direct-proxy-accept")
                        .apply { isDaemon = true }.start()
                }
                port = server.localPort
            } catch (e: Exception) { error = e }
            pending = attempt
        }
        pending?.let { a ->
            if (error != null) failAttempt(a, "PROXY_START_FAILED", error?.message)
            else if (port != null) succeedAttempt(a, port!!)
        }
    }

    private fun succeedAttempt(a: StartAttempt, port: Int) {
        val waiters = synchronized(lock) {
            if (attempt !== a || a.gen != generation || currentNetwork == null) return
            attempt = null
            a.timeout?.cancel(false)
            a.waiters.toList().also { a.waiters.clear() }
        }
        waiters.forEach { try { it.success(port) } catch (_: Exception) {} }
    }

    private fun failAttempt(a: StartAttempt, code: String, message: String?) {
        val waiters = synchronized(lock) {
            if (attempt !== a || a.gen != generation) return
            attempt = null
            generation++
            a.timeout?.cancel(false)
            clearLocked()
            a.waiters.toList().also { a.waiters.clear() }
        }
        waiters.forEach { replyError(it, code, message) }
    }

    private fun acceptLoop(server: ServerSocket) {
        while (!server.isClosed) {
            val client = try { server.accept() } catch (_: Exception) { break }
            if (!slots.tryAcquire()) { closeQuietly(client); continue }
            val accepted = synchronized(lock) {
                if (listener !== server || server.isClosed) false
                else { tracked.add(client); true }
            }
            if (!accepted) {
                closeQuietly(client)
                slots.release()
                continue
            }
            try {
                workers.execute {
                    try { handleClient(client) } catch (_: Exception) {}
                    finally {
                        tracked.remove(client)
                        closeQuietly(client)
                        slots.release()
                    }
                }
            } catch (_: Exception) {
                tracked.remove(client)
                closeQuietly(client)
                slots.release()
            }
        }
    }

    private fun handleClient(client: Socket) {
        var remote: Socket? = null
        var sending: Future<*>? = null
        val out = client.getOutputStream()
        var responseStarted = false
        var readingUpstream = false
        try {
            client.soTimeout = IO_TIMEOUT_MS
            val input = BufferedInputStream(client.getInputStream())
            val head = DirectProxyProtocol.readHead(input)
            val (method, target, version) = DirectProxyProtocol.parseRequestLine(head.startLine)
            val connect = method == "CONNECT"
            val destination = if (connect) DirectProxyProtocol.connectAuthority(target) to ""
                else DirectProxyProtocol.absoluteToOrigin(target)
            if (!connect) DirectProxyProtocol.validateRequestHeaders(head.headers)
            val network = synchronized(lock) { currentNetwork }
                ?: run { sendError(out, 503, "Service Unavailable"); return }
            remote = try { connectRemote(network, destination.first) }
                catch (_: Exception) { sendError(out, 502, "Bad Gateway"); return }
            val peer = remote
            val peerOut = peer.getOutputStream()
            val peerIn = BufferedInputStream(peer.getInputStream())
            if (connect) {
                responseStarted = true
                out.write("HTTP/1.1 200 Connection Established\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
                out.flush()
                client.soTimeout = 0
                peer.soTimeout = 0
                sending = workers.submit(Runnable {
                    try { input.copyTo(peerOut) } finally { closeQuietly(peer) }
                })
                peerIn.copyTo(out)
                out.flush()
                return
            }

            val headers = DirectProxyProtocol.forwardHeaders(head.headers, destination.first)
                .filterNot { it.first.equals("Expect", true) }
            peerOut.write(DirectProxyProtocol.buildRequestHead(method, destination.second, version, headers))
            peerOut.flush()
            if (DirectProxyProtocol.firstHeader(head.headers, "Expect")?.equals("100-continue", true) == true) {
                out.write("HTTP/1.1 100 Continue\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
                out.flush()
            }
            // 同时读取响应；请求体发送完继续监测客户端关闭，让取消能关闭出站 socket。
            sending = workers.submit(Runnable {
                try {
                    pumpBody(input, peerOut, headers)
                    peerOut.flush()
                    client.soTimeout = 0
                    while (input.read() != -1) { /* 此连接不接受下一条请求。 */ }
                } finally { closeQuietly(peer) }
            })
            readingUpstream = true
            var response = DirectProxyProtocol.readHead(peerIn)
            var code = DirectProxyProtocol.statusCode(response.startLine)
            while (code in 100..199 && code != 101) {
                out.write(DirectProxyProtocol.buildResponseHead(response.startLine,
                    DirectProxyProtocol.forwardHeaders(response.headers)))
                out.flush()
                response = DirectProxyProtocol.readHead(peerIn)
                code = DirectProxyProtocol.statusCode(response.startLine)
            }
            if (code == 101) { sendError(out, 502, "Unsupported Upgrade"); return }
            val responseHeaders = DirectProxyProtocol.forwardHeaders(response.headers).let { values ->
                if (DirectProxyProtocol.firstHeader(values, "Transfer-Encoding") != null)
                    values.filterNot { it.first.equals("Content-Length", true) } else values
            }
            responseStarted = true
            out.write(DirectProxyProtocol.buildResponseHead(response.startLine, responseHeaders))
            out.flush()
            peer.soTimeout = 0
            if (method != "HEAD" && code != 204 && code != 304) peerIn.copyTo(out)
            out.flush()
        } catch (_: DirectProxyProtocol.BadRequest) {
            if (!responseStarted) sendError(out,
                if (readingUpstream) 502 else 400, if (readingUpstream) "Bad Gateway" else "Bad Request")
        } catch (_: IOException) {
            if (!responseStarted) sendError(out, 502, "Bad Gateway")
        } finally {
            closeQuietly(client)
            remote?.let { tracked.remove(it); closeQuietly(it) }
            sending?.cancel(true)
        }
    }

    private fun connectRemote(network: Network, authority: DirectProxyProtocol.Authority): Socket {
        val lookup = dns.submit(Callable { network.getAllByName(authority.host) })
        val addresses = try {
            lookup.get(IO_TIMEOUT_MS.toLong(), TimeUnit.MILLISECONDS)
        } finally {
            lookup.cancel(true)
            dns.purge()
        }
        if (addresses.isEmpty()) throw IOException("DNS 无结果")
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(IO_TIMEOUT_MS.toLong())
        var lastError: IOException? = null
        for (address in addresses) {
            val remaining = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime()).toInt()
            if (remaining <= 0) break
            val socket = network.socketFactory.createSocket()
            synchronized(lock) {
                if (currentNetwork != network || listener == null) {
                    closeQuietly(socket)
                    throw IOException("非 VPN 网络已失效")
                }
                // 建连前登记，stop 和 onLost 也能关闭在途 socket。
                tracked.add(socket)
            }
            try {
                val timeout = if (addresses.size > 1) minOf(remaining, 5000) else remaining
                socket.connect(InetSocketAddress(address, authority.port), timeout)
                socket.soTimeout = IO_TIMEOUT_MS
                return socket
            } catch (error: Exception) {
                tracked.remove(socket)
                closeQuietly(socket)
                if (error !is IOException) throw error
                lastError = error
            }
        }
        throw lastError ?: IOException("直连连接超时")
    }

    private fun pumpBody(input: InputStream, out: OutputStream, headers: List<Pair<String, String>>) {
        val coding = DirectProxyProtocol.firstHeader(headers, "Transfer-Encoding")
        if (coding != null) {
            while (true) {
                val line = readChunkLine(input)
                val raw = String(line, Charsets.ISO_8859_1).substringBefore(';').trim()
                if (raw.isEmpty() || raw.any { it !in '0'..'9' && it !in 'a'..'f' && it !in 'A'..'F' })
                    throw DirectProxyProtocol.BadRequest("非法 chunk 尺寸")
                val size = raw.toLongOrNull(16) ?: throw DirectProxyProtocol.BadRequest("chunk 尺寸溢出")
                out.write(line); out.write(13); out.write(10)
                if (size == 0L) {
                    var total = 0
                    while (true) {
                        val trailer = readChunkLine(input)
                        total += trailer.size + 2
                        if (total > DirectProxyProtocol.MAX_HEADER_BYTES) throw DirectProxyProtocol.BadRequest("trailer 过长")
                        out.write(trailer); out.write(13); out.write(10)
                        if (trailer.isEmpty()) return
                    }
                }
                copyExactly(input, out, size)
                if (input.read() != 13 || input.read() != 10) throw DirectProxyProtocol.BadRequest("chunk 缺少 CRLF")
                out.write(13); out.write(10)
            }
        }
        val length = DirectProxyProtocol.firstHeader(headers, "Content-Length")?.toLong() ?: 0L
        copyExactly(input, out, length)
    }

    private fun copyExactly(input: InputStream, out: OutputStream, length: Long) {
        var remaining = length
        val buffer = ByteArray(8192)
        while (remaining > 0) {
            val count = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
            if (count < 0) throw DirectProxyProtocol.BadRequest("请求体提前结束")
            out.write(buffer, 0, count)
            remaining -= count
        }
    }

    private fun readChunkLine(input: InputStream): ByteArray {
        val line = ByteArrayOutputStream()
        while (line.size() < 16 * 1024) {
            val value = input.read()
            if (value < 0) throw DirectProxyProtocol.BadRequest("chunk 头提前结束")
            if (value == 13) {
                if (input.read() != 10) throw DirectProxyProtocol.BadRequest("chunk 缺少 CRLF")
                return line.toByteArray()
            }
            if (value < 32 && value != 9 || value == 127) throw DirectProxyProtocol.BadRequest("chunk 非法字符")
            line.write(value)
        }
        throw DirectProxyProtocol.BadRequest("chunk 头过长")
    }

    private fun sendError(out: OutputStream, code: Int, reason: String) {
        try {
            out.write("HTTP/1.1 $code $reason\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
                .toByteArray(Charsets.ISO_8859_1))
            out.flush()
        } catch (_: Exception) {}
    }

    private fun replyError(result: MethodChannel.Result, code: String, message: String?) {
        try { result.error(code, message, null) } catch (_: Exception) {}
    }

    private fun closeQuietly(value: Closeable?) {
        try { value?.close() } catch (_: Exception) {}
    }
}
