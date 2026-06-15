package dev.srsouza.jaca

import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/// On-phone loopback bridge for HTTPS decryption. The native engine DNATs TLS(443)
/// connections here; the bridge peeks the SNI host and tunnels the connection to the
/// desktop's MITM proxy via HTTP CONNECT, so the desktop decrypts (the CA private key never
/// leaves the desktop). If no desktop proxy is set or it's unreachable, the bridge resolves
/// the host and relays directly, so the device never loses connectivity.
///
/// The bridge's upstream sockets live in this app, which is excluded from the VPN
/// (addDisallowedApplication), so they reach the LAN/internet directly without protect().
class TunnelBridge {
    private var server: ServerSocket? = null
    @Volatile private var running = false
    private val proxy = AtomicReference<InetSocketAddress?>(null)
    /// Hosts to pass through directly (their client rejected the desktop cert), so decryption
    /// is best-effort: intercept what cooperates, and let everything else keep working.
    private val bypass = AtomicReference<Set<String>>(emptySet())

    fun start(): Int {
        val s = ServerSocket()
        s.bind(InetSocketAddress("127.0.0.1", 0)) // loopback, ephemeral
        server = s
        running = true
        thread(name = "jaca-bridge-accept") { acceptLoop(s) }
        return s.localPort
    }

    fun setProxy(host: String, port: Int, bypassHosts: Set<String> = emptySet()) {
        proxy.set(InetSocketAddress(host, port))
        bypass.set(bypassHosts)
    }
    fun clearProxy() { proxy.set(null); bypass.set(emptySet()) }

    fun stop() {
        running = false
        runCatching { server?.close() }
        server = null
    }

    private fun acceptLoop(s: ServerSocket) {
        while (running) {
            val client = try { s.accept() } catch (_: Exception) { if (running) continue else break }
            thread(name = "jaca-bridge-conn") { handle(client) }
        }
    }

    private fun handle(client: Socket) {
        try {
            client.tcpNoDelay = true
            val cin = client.getInputStream()
            val cout = client.getOutputStream()
            // Peek the ClientHello for SNI (the DNAT dropped the original destination IP).
            val peek = ByteArray(BUFFER)
            val n = cin.read(peek)
            if (n <= 0) return
            val host = TlsSni.host(peek, n) ?: return // non-SNI TLS: can't route it

            val upstream = openUpstream(host) ?: return
            try {
                upstream.getOutputStream().apply { write(peek, 0, n); flush() } // replay ClientHello
                relay(cin, cout, upstream)
            } finally {
                runCatching { upstream.close() }
            }
        } catch (_: Exception) {
        } finally {
            runCatching { client.close() }
        }
    }

    /// Tunnel through the desktop proxy via CONNECT (decryption), or fall back to direct.
    private fun openUpstream(host: String): Socket? {
        // Skip the proxy for bypassed hosts (their client rejects the cert) — go direct.
        if (!bypass.get().contains(host)) proxy.get()?.let { p ->
            runCatching {
                val s = Socket().apply { tcpNoDelay = true; connect(p, PROXY_TIMEOUT) }
                val req = "CONNECT $host:443 HTTP/1.1\r\nHost: $host:443\r\n\r\n"
                s.getOutputStream().apply { write(req.toByteArray(Charsets.US_ASCII)); flush() }
                if (!readHttpOk(s.getInputStream())) { s.close(); throw java.io.IOException("proxy refused") }
                s
            }.getOrNull()?.let { return it }
            // proxy unreachable -> fall through to a direct connection
        }
        return runCatching {
            Socket().apply { tcpNoDelay = true; connect(InetSocketAddress(host, 443), DIRECT_TIMEOUT) }
        }.getOrNull()
    }

    private fun relay(cin: InputStream, cout: OutputStream, upstream: Socket) {
        val c2u = thread(name = "jaca-bridge-c2u") {
            runCatching { copy(cin, upstream.getOutputStream()) }
            runCatching { upstream.shutdownOutput() }
        }
        runCatching { copy(upstream.getInputStream(), cout) }
        c2u.join(JOIN_MS)
    }

    private fun copy(from: InputStream, to: OutputStream) {
        val buf = ByteArray(BUFFER)
        while (true) {
            val r = from.read(buf); if (r < 0) break
            if (r > 0) { to.write(buf, 0, r); to.flush() }
        }
    }

    private fun readHttpOk(input: InputStream): Boolean {
        val sb = StringBuilder()
        val one = ByteArray(1)
        while (sb.length < 8192) {
            if (input.read(one) < 0) return false
            sb.append(one[0].toInt().toChar())
            if (sb.length >= 4 && sb.endsWith("\r\n\r\n")) break
        }
        return sb.takeWhile { it != '\r' }.contains(" 2")
    }

    companion object {
        private const val BUFFER = 32 * 1024
        private const val PROXY_TIMEOUT = 2000
        private const val DIRECT_TIMEOUT = 10000
        private const val JOIN_MS = 1000L
    }
}
