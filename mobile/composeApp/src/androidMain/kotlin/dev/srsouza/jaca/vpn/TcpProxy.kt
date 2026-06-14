package dev.srsouza.jaca.vpn

import android.net.VpnService
import android.system.Os
import android.system.OsConstants
import java.io.FileDescriptor
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.concurrent.thread

/// Local TCP relay. App connections are redirected here by [TcpForwarder] (header rewrite),
/// so the kernel completes the app-side TCP for us. For each accepted connection we open a
/// `protect()`-ed upstream socket to the real destination and pump bytes both ways; the
/// protected upstream bypasses the VPN, keeping the device online while we sit in the middle.
///
/// The listening socket is a **true AF_INET** socket created via `Os.socket`, not a NIO
/// ServerSocketChannel: Android's NIO only makes IPv6/v4-mapped sockets, and the kernel does
/// not deliver our tun-reinjected IPv4 packets (foreign source, dst = the tun address) to
/// those — so accept() never fires and the device's TCP silently dies. An AF_INET socket
/// receives them. The relay is blocking, thread-per-connection (simple; fine for a dev tool).
class TcpProxy(
    private val vpn: VpnService,
    private val sessions: SessionProvider,
    private val bindIp: String,
) {
    /// When set (the desktop sent its decryption-proxy address), TLS connections are
    /// tunnelled there via HTTP CONNECT so the desktop can MITM-decrypt them. Everything
    /// else — and all connections if the proxy turns out unreachable — goes direct, so the
    /// device stays online regardless.
    @Volatile var tunnel: InetSocketAddress? = null
        set(value) { field = value; if (value != null) proxyReachable = true }

    /// Cleared once a proxy connect fails, so we stop paying the connect timeout on every
    /// TLS connection and go direct until the desktop (re)advertises a reachable proxy.
    @Volatile private var proxyReachable = true

    private val listenFd: FileDescriptor =
        Os.socket(OsConstants.AF_INET, OsConstants.SOCK_STREAM, OsConstants.IPPROTO_TCP)
    val port: Short

    @Volatile private var running = false
    private var acceptThread: Thread? = null

    init {
        Os.setsockoptInt(listenFd, OsConstants.SOL_SOCKET, OsConstants.SO_REUSEADDR, 1)
        Os.bind(listenFd, InetAddress.getByName(bindIp), 0)
        Os.listen(listenFd, BACKLOG)
        port = (Os.getsockname(listenFd) as InetSocketAddress).port.toShort()
    }

    fun start() {
        running = true
        acceptThread = thread(name = "jaca-tcp-proxy") { acceptLoop() }
    }

    fun stop() {
        running = false
        runCatching { Os.close(listenFd) } // unblocks accept()
    }

    private fun acceptLoop() {
        while (running) {
            val clientFd = try {
                Os.accept(listenFd, null)
            } catch (_: Exception) {
                if (running) continue else break
            } ?: continue
            // Accepted peer = the rewritten realDest:appSrcPort; the app's source port keys the session.
            val srcPort = runCatching { (Os.getpeername(clientFd) as InetSocketAddress).port.toShort() }.getOrNull()
            val session = srcPort?.let { sessions.query(it) }
            if (session == null) { runCatching { Os.close(clientFd) }; continue }
            thread(name = "jaca-conn") { handle(clientFd, session) }
        }
    }

    private fun handle(clientFd: FileDescriptor, session: Session) {
        try {
            val t = tunnel
            if (t != null && proxyReachable) tunnelOrDirect(clientFd, session, t)
            else relayDirect(clientFd, session, null, 0)
        } catch (_: Exception) {
            // per-connection failure: just drop it
        } finally {
            runCatching { Os.close(clientFd) }
        }
    }

    /// TLS connection: peek the ClientHello for SNI, tunnel it to the desktop proxy via HTTP
    /// CONNECT, and fall back to a direct relay if the proxy can't be reached. Non-TLS goes
    /// direct immediately. The peeked bytes are replayed to whichever upstream we use.
    private fun tunnelOrDirect(clientFd: FileDescriptor, session: Session, proxy: InetSocketAddress) {
        val peek = ByteArray(BUFFER)
        val n = try { Os.read(clientFd, peek, 0, peek.size) } catch (_: Exception) { return }
        if (n <= 0) return
        val host = if ((peek[0].toInt() and 0xFF) == 0x16) TlsSni.host(peek, n) else null
        if (host == null) { relayDirect(clientFd, session, peek, n); return } // not TLS

        val up = Socket()
        if (!vpn.protect(up)) { runCatching { up.close() }; return }
        try {
            up.connect(proxy, PROXY_TIMEOUT_MS)
            val p = session.remotePort.toUnsignedPort()
            val req = "CONNECT $host:$p HTTP/1.1\r\nHost: $host:$p\r\nX-Jaca-App: ${session.packageName ?: ""}\r\n\r\n"
            up.getOutputStream().apply { write(req.toByteArray(Charsets.US_ASCII)); flush() }
            if (!readHttpOk(up.getInputStream())) throw IOException("proxy refused CONNECT")
            relay(clientFd, up, peek, n)
        } catch (_: Exception) {
            runCatching { up.close() }
            proxyReachable = false // proxy unreachable: stop tunnelling until re-advertised
            relayDirect(clientFd, session, peek, n) // never lose connectivity
        }
    }

    /// Connect straight to the real destination and relay, replaying any peeked prelude.
    private fun relayDirect(clientFd: FileDescriptor, session: Session, prelude: ByteArray?, preludeLen: Int) {
        val dest = InetSocketAddress(intToInetAddress(session.remoteIp), session.remotePort.toUnsignedPort())
        val up = Socket()
        if (!vpn.protect(up)) { runCatching { up.close() }; return }
        try {
            up.connect(dest, CONNECT_TIMEOUT_MS)
            relay(clientFd, up, prelude, preludeLen)
        } catch (_: Exception) {
            runCatching { up.close() }
        }
    }

    /// Full-duplex pump between the app-side [clientFd] and the [upstream] socket. One thread
    /// copies client->upstream; this thread copies upstream->client.
    private fun relay(clientFd: FileDescriptor, upstream: Socket, prelude: ByteArray?, preludeLen: Int) {
        val upOut = upstream.getOutputStream()
        if (prelude != null && preludeLen > 0) { upOut.write(prelude, 0, preludeLen); upOut.flush() }
        val c2r = thread(name = "jaca-conn-c2r") {
            runCatching { copyFdToStream(clientFd, upOut) }
            runCatching { upstream.shutdownOutput() }
        }
        runCatching { copyStreamToFd(upstream.getInputStream(), clientFd) }
        runCatching { upstream.close() }
        c2r.join(JOIN_MS)
    }

    private fun copyFdToStream(fd: FileDescriptor, to: OutputStream) {
        val buf = ByteArray(BUFFER)
        while (true) {
            val n = try { Os.read(fd, buf, 0, buf.size) } catch (_: Exception) { break }
            if (n <= 0) break
            to.write(buf, 0, n); to.flush()
        }
    }

    private fun copyStreamToFd(from: InputStream, fd: FileDescriptor) {
        val buf = ByteArray(BUFFER)
        while (true) {
            val n = from.read(buf)
            if (n < 0) break
            var off = 0
            while (off < n) {
                val w = try { Os.write(fd, buf, off, n - off) } catch (_: Exception) { return }
                if (w <= 0) return
                off += w
            }
        }
    }

    /// Read an HTTP CONNECT response up to the blank line; true iff it's a 2xx.
    private fun readHttpOk(input: InputStream): Boolean {
        val sb = StringBuilder()
        val one = ByteArray(1)
        while (sb.length < 8192) {
            if (input.read(one) < 0) return false
            sb.append(one[0].toInt().toChar())
            if (sb.length >= 4 && sb.endsWith("\r\n\r\n")) break
        }
        val firstLine = sb.takeWhile { it != '\r' }
        return firstLine.contains(" 2")
    }

    companion object {
        private const val BUFFER = 32 * 1024
        private const val BACKLOG = 128
        private const val PROXY_TIMEOUT_MS = 2000    // desktop-proxy connect budget before going direct
        private const val CONNECT_TIMEOUT_MS = 10000 // direct upstream connect budget
        private const val JOIN_MS = 1000L
    }
}

/// Rewrites tun TCP packets to redirect app->server connections at our local proxy (and
/// rewrites the proxy's replies back), so the kernel TCP-terminates both ends. Runs on the
/// tun reader thread. Ported from NetBare's TcpProxyServerForwarder (MIT).
class TcpForwarder(
    private val proxyIp: Int,
    private val proxyPort: Short,
    private val sessions: SessionProvider,
    private val output: OutputStream,
    private val writeLock: Any,
    private val onSession: (Session) -> Unit,
) {
    fun forward(packet: ByteArray, len: Int) {
        val ip = IpHeader(packet, 0)
        val tcp = TcpHeader(ip, packet, ip.getHeaderLength())
        val localPort = tcp.getSourcePort()
        val remoteIp = ip.getDestinationIp()
        val remotePort = tcp.getDestinationPort()

        if (localPort != proxyPort) {
            // App -> server: record the real destination, then redirect to our proxy.
            // Attribute on the first SYN (reader thread), where getConnectionOwnerUid is reliable.
            val session = sessions.ensureQuery(Protocol.TCP, localPort, remotePort, remoteIp)
            if (!session.attributed) onSession(session)
            ip.setSourceIp(remoteIp)        // src becomes the real dest (so accept() peer = realDest:srcPort)
            ip.setDestinationIp(proxyIp)    // dst becomes the local proxy (tun address)
            tcp.setDestinationPort(proxyPort)
        } else {
            // Proxy -> app reply: restore so the app sees it coming from the real server.
            val session = sessions.query(remotePort) ?: return
            ip.setSourceIp(remoteIp)
            ip.setDestinationIp(proxyIp)
            tcp.setSourcePort(session.remotePort)
        }
        ip.updateChecksum()
        tcp.updateChecksum()
        synchronized(writeLock) {
            runCatching { output.write(packet, 0, len) }
        }
    }
}
