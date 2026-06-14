package dev.srsouza.jaca.vpn

import android.net.VpnService
import android.os.SystemClock
import java.io.OutputStream
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.channels.DatagramChannel
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue

/// UDP relay. Unlike TCP there's no redirect/accept: the forwarder hands each outbound
/// datagram here, we send it over a `protect()`-ed DatagramChannel to the real
/// destination, and synthesize reply packets straight back into the tun. One channel per
/// source port (so DNS, QUIC, etc. keep working and the device stays online).
class UdpProxy(
    private val vpn: VpnService,
    private val sessions: SessionProvider,
    private val output: OutputStream,
    private val writeLock: Any,
    private val onSession: (Session) -> Unit,
) {
    private val selector: Selector = Selector.open()
    private val conns = ConcurrentHashMap<Short, Conn>()
    private val pendingRegister = ConcurrentLinkedQueue<Conn>()
    @Volatile private var running = false
    private val thread = Thread(::loop, "jaca-udp-proxy")

    fun start() { running = true; thread.start() }

    fun stop() {
        running = false
        selector.wakeup()
        conns.values.forEach { it.close() }
        conns.clear()
        runCatching { selector.close() }
    }

    /// Called on the tun reader thread for each outbound UDP packet.
    fun send(udp: UdpHeader) {
        val ip = udp.ip
        val localPort = udp.getSourcePort()
        val remoteIp = ip.getDestinationIp()
        val remotePort = udp.getDestinationPort()
        val session = sessions.ensureQuery(Protocol.UDP, localPort, remotePort, remoteIp)

        var conn = conns[localPort]
        if (conn == null || conn.remoteIp != remoteIp || conn.remotePort != remotePort) {
            conn?.close()
            conn = try {
                Conn(localPort, remoteIp, remotePort, buildTemplate(udp))
            } catch (_: Exception) { return }
            conns[localPort] = conn
            onSession(session)
            pendingRegister.add(conn)
            selector.wakeup()
        }
        conn.lastUse = SystemClock.elapsedRealtime()
        runCatching { conn.channel.write(ByteBuffer.wrap(udp.data())) }
    }

    private fun loop() {
        while (running) {
            try {
                while (true) {
                    val c = pendingRegister.poll() ?: break
                    runCatching { c.key = c.channel.register(selector, SelectionKey.OP_READ, c) }
                }
                if (selector.select(SELECT_TIMEOUT) == 0) { evictIdle(); continue }
                val it = selector.selectedKeys().iterator()
                while (it.hasNext()) {
                    val key = it.next(); it.remove()
                    if (key.isValid && key.isReadable) (key.attachment() as Conn).onReadable()
                }
                evictIdle()
            } catch (_: Exception) {
                // keep loop alive
            }
        }
    }

    private fun evictIdle() {
        val now = SystemClock.elapsedRealtime()
        val expired = conns.values.filter { now - it.lastUse > IDLE_MS }
        for (c in expired) { conns.remove(c.localPort); c.close() }
    }

    private fun buildTemplate(udp: UdpHeader): ByteArray {
        val tmpl = udp.copy()
        val tip = tmpl.ip
        val s = tip.getSourceIp(); val d = tip.getDestinationIp()
        tip.setSourceIp(d); tip.setDestinationIp(s)
        val sp = tmpl.getSourcePort(); val dp = tmpl.getDestinationPort()
        tmpl.setSourcePort(dp); tmpl.setDestinationPort(sp)
        return tmpl.packet.copyOf(tip.getHeaderLength() + 8)  // IP header + UDP header, addresses swapped
    }

    private inner class Conn(
        val localPort: Short,
        val remoteIp: Int,
        val remotePort: Short,
        private val template: ByteArray,
    ) {
        val channel: DatagramChannel = DatagramChannel.open()
        var key: SelectionKey? = null
        @Volatile var lastUse = SystemClock.elapsedRealtime()
        private val ipHeaderLen = IpHeader(template, 0).getHeaderLength()

        init {
            channel.configureBlocking(false)
            if (!vpn.protect(channel.socket())) throw java.io.IOException("protect failed")
            channel.connect(InetSocketAddress(intToInetAddress(remoteIp), remotePort.toUnsignedPort()))
        }

        fun onReadable() {
            val buf = ByteBuffer.allocate(MTU)
            val n = try { channel.read(buf) } catch (_: Exception) { close(); conns.remove(localPort); return }
            if (n <= 0) return
            buf.flip()
            lastUse = SystemClock.elapsedRealtime()
            val total = ipHeaderLen + 8 + n
            val pkt = ByteArray(total)
            System.arraycopy(template, 0, pkt, 0, ipHeaderLen + 8)
            buf.get(pkt, ipHeaderLen + 8, n)
            val ip = IpHeader(pkt, 0)
            ip.setTotalLength(total.toShort())
            val udp = UdpHeader(ip, pkt, ipHeaderLen)
            udp.setTotalLength((total - ipHeaderLen).toShort())
            ip.updateChecksum()
            udp.updateChecksum()
            synchronized(writeLock) { runCatching { output.write(pkt, 0, total) } }
        }

        fun close() {
            runCatching { key?.cancel() }
            runCatching { channel.close() }
        }
    }

    companion object {
        private const val SELECT_TIMEOUT = 2000L
        private const val IDLE_MS = 30_000L
        private const val MTU = 64 * 1024
    }
}
