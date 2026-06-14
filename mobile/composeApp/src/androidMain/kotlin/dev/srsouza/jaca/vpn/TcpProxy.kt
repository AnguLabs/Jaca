package dev.srsouza.jaca.vpn

import android.net.VpnService
import java.io.OutputStream
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.nio.channels.ServerSocketChannel
import java.nio.channels.SocketChannel

/// Local TCP relay. App connections are redirected here by [TcpForwarder] (header
/// rewrite), so the kernel completes the app-side TCP for us. For each accepted
/// connection we open a `protect()`-ed upstream socket to the real destination and pump
/// bytes both ways. Because the upstream socket is protected, its traffic bypasses the
/// VPN — that's what keeps the device online while we sit in the middle.
class TcpProxy(
    private val vpn: VpnService,
    private val sessions: SessionProvider,
) {
    private val selector: Selector = Selector.open()
    private val server: ServerSocketChannel = ServerSocketChannel.open().apply {
        configureBlocking(false)
        socket().bind(InetSocketAddress(0))
        register(selector, SelectionKey.OP_ACCEPT)
    }
    val port: Short = server.socket().localPort.toShort()

    @Volatile private var running = false
    private val thread = Thread(::loop, "jaca-tcp-proxy")

    fun start() { running = true; thread.start() }

    fun stop() {
        running = false
        selector.wakeup()
        runCatching { selector.close() }
        runCatching { server.close() }
    }

    private fun loop() {
        while (running) {
            try {
                if (selector.select(SELECT_TIMEOUT) == 0) continue
                val it = selector.selectedKeys().iterator()
                while (it.hasNext()) {
                    val key = it.next(); it.remove()
                    if (!key.isValid) continue
                    when {
                        key.isAcceptable -> onAccept()
                        key.isConnectable -> (key.attachment() as Conn).onConnectable()
                        else -> (key.attachment() as Conn).onIo(key)
                    }
                }
            } catch (_: Exception) {
                // keep the loop alive; per-connection errors close their own Conn
            }
        }
    }

    private fun onAccept() {
        val client = server.accept() ?: return
        try {
            client.configureBlocking(false)
            // Accepted peer = the rewritten (realDest : appSrcPort). The source port keys the session.
            val srcPort = client.socket().port.toShort()
            val session = sessions.query(srcPort)
            if (session == null) { client.close(); return }
            val remote = SocketChannel.open()
            remote.configureBlocking(false)
            if (!vpn.protect(remote.socket())) { client.close(); remote.close(); return }
            val conn = Conn(client, remote)
            val dest = InetSocketAddress(intToInetAddress(session.remoteIp), session.remotePort.toUnsignedPort())
            remote.connect(dest)
            remote.register(selector, SelectionKey.OP_CONNECT, conn)
        } catch (_: Exception) {
            runCatching { client.close() }
        }
    }

    /// One accepted connection: app-side [client] <-> upstream [remote], two one-way pipes.
    private inner class Conn(val client: SocketChannel, val remote: SocketChannel) {
        private lateinit var clientKey: SelectionKey
        private lateinit var remoteKey: SelectionKey
        private val c2r = Pipe()  // client -> remote
        private val r2c = Pipe()  // remote -> client
        private var closed = false

        fun onConnectable() {
            try {
                if (remote.finishConnect()) {
                    clientKey = client.register(selector, 0, this)
                    remoteKey = remote.register(selector, 0, this)
                    updateInterest()
                }
            } catch (_: Exception) { close() }
        }

        fun onIo(key: SelectionKey) {
            try {
                val ch = key.channel()
                if (key.isReadable) {
                    if (ch === client) read(client, remote, c2r) else read(remote, client, r2c)
                }
                if (key.isValid && key.isWritable) {
                    if (ch === client) write(client, r2c) else write(remote, c2r)
                }
                updateInterest()
            } catch (_: Exception) { close() }
        }

        private fun read(src: SocketChannel, dst: SocketChannel, pipe: Pipe) {
            if (pipe.hasData || pipe.eof) return
            val n = src.read(pipe.buf)
            if (n == -1) {
                pipe.eof = true
            } else if (n > 0) {
                pipe.buf.flip()
                pipe.hasData = true
                // opportunistic immediate write to reduce latency
                dst.write(pipe.buf)
                if (!pipe.buf.hasRemaining()) { pipe.buf.clear(); pipe.hasData = false }
            }
        }

        private fun write(dst: SocketChannel, pipe: Pipe) {
            if (!pipe.hasData) return
            dst.write(pipe.buf)
            if (!pipe.buf.hasRemaining()) { pipe.buf.clear(); pipe.hasData = false }
        }

        private fun updateInterest() {
            if (closed) return
            // Half-close: once a side is fully drained + EOF, signal the peer with a FIN.
            if (c2r.eof && !c2r.hasData && !c2r.shutdown) {
                runCatching { remote.shutdownOutput() }; c2r.shutdown = true
            }
            if (r2c.eof && !r2c.hasData && !r2c.shutdown) {
                runCatching { client.shutdownOutput() }; r2c.shutdown = true
            }
            if (c2r.done() && r2c.done()) { close(); return }
            var clientOps = 0
            var remoteOps = 0
            if (!c2r.eof && !c2r.hasData) clientOps = clientOps or SelectionKey.OP_READ
            if (c2r.hasData) remoteOps = remoteOps or SelectionKey.OP_WRITE
            if (!r2c.eof && !r2c.hasData) remoteOps = remoteOps or SelectionKey.OP_READ
            if (r2c.hasData) clientOps = clientOps or SelectionKey.OP_WRITE
            if (clientKey.isValid) clientKey.interestOps(clientOps)
            if (remoteKey.isValid) remoteKey.interestOps(remoteOps)
        }

        private fun close() {
            if (closed) return
            closed = true
            runCatching { client.close() }
            runCatching { remote.close() }
        }
    }

    private class Pipe {
        val buf: ByteBuffer = ByteBuffer.allocate(BUFFER)  // empty => fill/read mode
        var hasData = false   // true => flipped, draining to dest
        var eof = false       // source reached EOF
        var shutdown = false  // peer already signalled FIN
        fun done(): Boolean = eof && !hasData
    }

    companion object {
        private const val SELECT_TIMEOUT = 2000L
        private const val BUFFER = 64 * 1024
    }
}

/// Rewrites tun TCP packets to redirect app->server connections at our local proxy (and
/// rewrites the proxy's replies back), so the kernel TCP-terminates both ends. Runs on
/// the tun reader thread. Ported from NetBare's TcpProxyServerForwarder (MIT).
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
