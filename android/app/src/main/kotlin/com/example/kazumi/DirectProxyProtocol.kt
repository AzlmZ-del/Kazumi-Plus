package com.example.kazumi

import java.io.IOException
import java.io.InputStream

/**
 * 本地代理协议层：只解析/改写头块，body 一律按原始字节透传。
 * 绝不对 socket 用 BufferedReader 读头——它的预读会吞掉随后的 body 字节；
 * 调用方须把同一个 BufferedInputStream 继续交给 body 泵。
 */
internal object DirectProxyProtocol {
    const val MAX_HEADER_BYTES = 64 * 1024
    private const val MAX_HEADER_LINES = 256
    private const val MAX_LINE_BYTES = 16 * 1024

    class BadRequest(message: String) : IOException(message)

    class Head(
        val startLine: String,
        val headers: MutableList<Pair<String, String>>,
    )

    class Authority(val host: String, val port: Int, val hostHeader: String)

    private val ALWAYS_STRIP = setOf(
        "connection", "proxy-connection", "proxy-authorization",
        "proxy-authenticate", "keep-alive", "upgrade",
    )
    // Content-Length / Transfer-Encoding 是帧界定头，绝不能被 Connection 提名清掉。
    private val FRAMING_HEADERS = setOf(
        "content-length", "transfer-encoding", "host", "trailer", "te",
    )

    private fun isToken(s: String): Boolean =
        s.isNotEmpty() && s.all { c ->
            c in '0'..'9' || c in 'A'..'Z' || c in 'a'..'z' ||
                c == '!' || c == '#' || c == '$' || c == '%' || c == '&' ||
                c == '\'' || c == '*' || c == '+' || c == '-' || c == '.' ||
                c == '^' || c == '_' || c == '`' || c == '|' || c == '~'
        }

    /** 逐字节读完一个头块；[input] 必须是后续还要用来读 body 的那个流。 */
    fun readHead(input: InputStream): Head {
        val lines = ArrayList<String>(16)
        val line = ByteArray(MAX_LINE_BYTES)
        var lineLen = 0
        var total = 0
        var prevCr = false
        var lineCount = 0
        while (true) {
            val b = input.read()
            if (b < 0) throw BadRequest("读头块时连接断开")
            total++
            if (total > MAX_HEADER_BYTES) throw BadRequest("头块超过 $MAX_HEADER_BYTES 字节")
            if (prevCr && b != 10) throw BadRequest("头块出现裸 CR")
            if (b == 13) {
                prevCr = true;
                continue
            }
            if (b == 10) {
                if (!prevCr) throw BadRequest("头块出现裸 LF")
                prevCr = false
                if (lineLen == 0) {
                    if (lineCount == 0) throw BadRequest("空头块")
                    break
                }
                lineCount++
                if (lineCount > MAX_HEADER_LINES) throw BadRequest("头块行数超过上限")
                lines.add(String(line, 0, lineLen, Charsets.ISO_8859_1))
                lineLen = 0
                continue
            }
            prevCr = false
            if (b < 32 && b != 9 || b == 127) throw BadRequest("头块含非法控制字符")
            if (lineLen >= MAX_LINE_BYTES) throw BadRequest("单行头过长")
            line[lineLen++] = b.toByte()
        }
        val startLine = lines[0]
        val headers = ArrayList<Pair<String, String>>(lines.size)
        for (i in 1 until lines.size) {
            val text = lines[i]
            if (text.startsWith(" ") || text.startsWith("\t")) {
                if (headers.isEmpty()) throw BadRequest("非法续行")
                val last = headers.removeAt(headers.size - 1)
                headers.add(last.first to (last.second + " " + text.trim()))
                continue
            }
            val colon = text.indexOf(':')
            if (colon <= 0) throw BadRequest("非法头字段: ${text.take(64)}")
            val name = text.substring(0, colon)
            if (!isToken(name)) throw BadRequest("非法头字段名: ${name.take(64)}")
            headers.add(name to text.substring(colon + 1).trim())
        }
        return Head(startLine, headers)
    }

    /** 校验首行方法、目标与版本（旧实现只 split 一次且完全不校验方法）。 */
    fun parseRequestLine(line: String): Triple<String, String, String> {
        val s1 = line.indexOf(' ')
        val s2 = if (s1 >= 0) line.indexOf(' ', s1 + 1) else -1
        if (s1 <= 0 || s2 <= s1 + 1) throw BadRequest("非法请求行: ${line.take(120)}")
        val method = line.substring(0, s1)
        val target = line.substring(s1 + 1, s2)
        val version = line.substring(s2 + 1)
        if (!isToken(method)) throw BadRequest("非法方法: ${method.take(64)}")
        if (version != "HTTP/1.1" && version != "HTTP/1.0") throw BadRequest("不支持的协议版本: $version")
        if (target.isEmpty() || target.any { it <= ' ' }) throw BadRequest("非法请求目标")
        return Triple(method, target, version)
    }

    /** 解析 host:port / [IPv6]:port；拒绝裸 IPv6 与任何 scheme/path/userinfo。 */
    fun parseAuthority(authority: String, defaultPort: Int): Authority {
        var host: String
        var port: Int
        if (authority.startsWith("[")) {
            val end = authority.indexOf(']')
            if (end < 0) throw BadRequest("IPv6 authority 缺少 ]")
            host = authority.substring(1, end)
            val rest = authority.substring(end + 1)
            port = when {
                rest.isEmpty() -> defaultPort
                rest.startsWith(":") -> rest.substring(1).toIntOrNull()
                    ?: throw BadRequest("非法 IPv6 端口")
                else -> throw BadRequest("IPv6 ] 后内容非法")
            }
            if (!host.contains(':')) throw BadRequest("括号内不是 IPv6")
        } else {
            val colon = authority.lastIndexOf(':')
            if (colon >= 0) {
                host = authority.substring(0, colon)
                port = authority.substring(colon + 1).toIntOrNull()
                    ?: throw BadRequest("非法端口: ${authority.take(80)}")
            } else {
                host = authority
                port = defaultPort
            }
            if (host.contains(':')) throw BadRequest("裸 IPv6 必须用 [] 包裹")
        }
        if (host.isEmpty()) throw BadRequest("空主机")
        if (host.any { c ->
                c == '/' || c == '\\' || c == '@' || c == '?' || c == '#' || c == '*' || c <= ' '
            }) throw BadRequest("authority 含非法字符")
        if (port <= 0 || port > 65535) throw BadRequest("端口越界: $port")
        val bracketed = if (host.contains(':')) "[$host]" else host
        val hostHeader = if (port == defaultPort) bracketed else "$bracketed:$port"
        return Authority(host, port, hostHeader)
    }

    fun connectAuthority(target: String): Authority {
        if (target.contains("://") || target.contains("/") || target.contains("?") || target.contains("#"))
            throw BadRequest("CONNECT 目标必须是 host:port")
        return parseAuthority(target, 443)
    }

    /** 绝对形式 http://authority/path?query -> (authority, origin-form)。不做 MITM。 */
    fun absoluteToOrigin(target: String): Pair<Authority, String> {
        if (target.startsWith("https://", ignoreCase = true))
            throw BadRequest("HTTPS 必须走 CONNECT，本代理不做 MITM")
        if (!target.startsWith("http://", ignoreCase = true))
            throw BadRequest("非法的绝对请求目标: ${target.take(120)}")
        val rest = target.substring(7)
        val slash = rest.indexOf('/')
        val question = rest.indexOf('?')
        val cut = when {
            slash >= 0 && question >= 0 -> minOf(slash, question)
            slash >= 0 -> slash
            question >= 0 -> question
            else -> rest.length
        }
        val authority = parseAuthority(rest.substring(0, cut), 80)
        val tail = rest.substring(cut)
        val origin = when {
            tail.isEmpty() -> "/"
            tail.startsWith("/") -> tail
            tail.startsWith("?") -> "/$tail"
            else -> throw BadRequest("非法的绝对请求目标")
        }
        if (origin.contains('#')) throw BadRequest("请求目标含 fragment")
        return authority to origin
    }

    fun validateRequestHeaders(headers: List<Pair<String, String>>) {
        val lengths = headers.filter { it.first.equals("Content-Length", true) }.map { it.second }
        val codings = headers.filter { it.first.equals("Transfer-Encoding", true) }.map { it.second }
        if (lengths.size > 1 || codings.size > 1 || lengths.isNotEmpty() && codings.isNotEmpty())
            throw BadRequest("请求体帧界定冲突")
        lengths.firstOrNull()?.let { raw ->
            if (raw.isEmpty() || raw.any { it !in '0'..'9' } || raw.toLongOrNull() == null)
                throw BadRequest("非法 Content-Length")
        }
        codings.firstOrNull()?.let { raw ->
            val values = raw.split(',').map { it.trim().lowercase() }
            if (values.any { !isToken(it) } || values.last() != "chunked" ||
                values.count { it == "chunked" } != 1) throw BadRequest("不支持的 Transfer-Encoding")
        }
        if (headers.count { it.first.equals("Host", true) } > 1) throw BadRequest("重复 Host")
    }

    fun firstHeader(headers: List<Pair<String, String>>, name: String): String? =
        headers.firstOrNull { it.first.equals(name, ignoreCase = true) }?.second

    /**
     * 清掉逐跳头：Proxy-*、Connection 及其提名头、Keep-Alive / Upgrade。
     * 保留 Content-Length / Transfer-Encoding 等帧界定头，body 才能原样透传。
     */
    fun forwardHeaders(
        headers: List<Pair<String, String>>,
        authority: Authority? = null,
    ): List<Pair<String, String>> {
        val nominated = HashSet<String>()
        headers.forEach { (name, value) ->
            val lower = name.lowercase()
            if (lower == "connection" || lower == "proxy-connection") {
                value.split(',').forEach { token ->
                    val t = token.trim().lowercase()
                    if (t.isNotEmpty() && t !in FRAMING_HEADERS) nominated.add(t)
                }
            }
        }
        val out = ArrayList<Pair<String, String>>(headers.size + 2)
        headers.forEach { h ->
            val lower = h.first.lowercase()
            if (lower !in ALWAYS_STRIP && lower !in nominated &&
                !(authority != null && lower == "host")) out.add(h)
        }
        if (authority != null) out.add("Host" to authority.hostHeader)
        return out
    }

    fun buildRequestHead(
        method: String,
        target: String,
        version: String,
        headers: List<Pair<String, String>>,
    ): ByteArray = buildHead("$method $target $version", headers)

    fun buildResponseHead(statusLine: String, headers: List<Pair<String, String>>): ByteArray =
        buildHead(statusLine, headers)

    private fun buildHead(startLine: String, headers: List<Pair<String, String>>): ByteArray {
        val sb = StringBuilder(startLine.length + headers.size * 32 + 64)
        sb.append(startLine).append("\r\n")
        headers.forEach { sb.append(it.first).append(": ").append(it.second).append("\r\n") }
        // 强制逐连接关闭：响应体可直接流到 EOF，无需自行缓冲完整响应。
        sb.append("Connection: close\r\n\r\n")
        return sb.toString().toByteArray(Charsets.ISO_8859_1)
    }

    fun statusCode(statusLine: String): Int {
        val fields = statusLine.split(' ', limit = 3)
        if (fields.size < 2 || (fields[0] != "HTTP/1.0" && fields[0] != "HTTP/1.1"))
            throw BadRequest("非法状态行")
        val code = fields[1].toIntOrNull() ?: throw BadRequest("非法状态码")
        if (fields[1].length != 3 || code !in 100..599) throw BadRequest("非法状态码")
        return code
    }
}
