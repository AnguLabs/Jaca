package dev.srsouza.jaca

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/// The companion link to Jaca desktop. Advertises this device over mDNS (so the desktop
/// finds it with no ADB), accepts desktop connections, and streams captured flows as
/// newline-delimited JSON. Decryption happens on the desktop, so nothing sensitive (no CA
/// key) lives here.
///
/// Each client gets its OWN bounded queue + writer thread, so [broadcast] (called from
/// the capture/tun thread) only ever does a non-blocking enqueue. A dead or stalled
/// desktop can never block packet forwarding — it just gets pruned. This is essential:
/// writing straight to a half-open socket on the capture thread would freeze the device's
/// whole network.
class DesktopBridge(
    private val context: Context,
    private val onConnectedChange: (Boolean) -> Unit,
) {
    private val clients = Collections.synchronizedList(mutableListOf<Client>())
    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null
    private var heartbeatThread: Thread? = null
    private var nsd: NsdManager? = null
    private var regListener: NsdManager.RegistrationListener? = null
    @Volatile private var running = false
    var port: Int = PORT
        private set

    fun start() {
        running = true
        val ss = runCatching { ServerSocket(PORT) }.getOrElse { ServerSocket(0) }
        serverSocket = ss
        port = ss.localPort
        acceptThread = Thread({ acceptLoop(ss) }, "jaca-bridge-accept").apply { start() }
        heartbeatThread = Thread({
            while (running) {
                runCatching { Thread.sleep(HEARTBEAT_MS) }
                if (!running) break
                broadcast("""{"type":"ping"}""")
            }
        }, "jaca-bridge-heartbeat").apply { start() }
        registerNsd(port)
    }

    fun stop() {
        running = false
        heartbeatThread?.interrupt(); heartbeatThread = null
        unregisterNsd()
        runCatching { serverSocket?.close() }
        synchronized(clients) { clients.toList().forEach { it.die() } }
        onConnectedChange(false)
    }

    /// Non-blocking: enqueues one JSON line per connected desktop. Safe to call from the
    /// capture thread because no socket I/O happens here.
    fun broadcast(line: String) {
        val bytes = (line + "\n").toByteArray()
        synchronized(clients) { clients.forEach { it.enqueue(bytes) } }
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (running) {
            val sock = runCatching { ss.accept() }.getOrNull() ?: break
            runCatching {
                sock.tcpNoDelay = true
                sock.keepAlive = true
                val client = Client(sock)
                clients.add(client)
                client.start()
                onConnectedChange(true)
            }
        }
    }

    /// One connected desktop: a bounded outgoing queue drained by a dedicated writer
    /// thread, plus a reader thread that only watches for disconnect.
    private inner class Client(private val socket: Socket) {
        private val queue = LinkedBlockingQueue<ByteArray>(QUEUE_CAP)
        @Volatile private var alive = true
        private val writer = Thread({ writeLoop() }, "jaca-bridge-writer")
        private val reader = Thread({ readLoop() }, "jaca-bridge-reader")

        fun start() { writer.start(); reader.start() }

        fun enqueue(bytes: ByteArray) {
            if (!queue.offer(bytes)) { queue.poll(); queue.offer(bytes) } // drop oldest if backed up
        }

        private fun writeLoop() {
            val out = runCatching { socket.getOutputStream() }.getOrNull() ?: return die()
            while (alive) {
                val bytes = try { queue.poll(2, TimeUnit.SECONDS) } catch (_: InterruptedException) { break } ?: continue
                try { out.write(bytes); out.flush() } catch (_: Exception) { return die() }
            }
        }

        private fun readLoop() {
            runCatching {
                val input = socket.getInputStream(); val buf = ByteArray(256)
                while (input.read(buf) >= 0) { /* desktop is a reader; just watch for EOF */ }
            }
            die()
        }

        fun die() {
            if (!alive) return
            alive = false
            runCatching { socket.close() }
            writer.interrupt()
            clients.remove(this)
            onConnectedChange(clients.isNotEmpty())
        }
    }

    private fun registerNsd(port: Int) {
        val manager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager ?: return
        nsd = manager
        val info = NsdServiceInfo().apply {
            serviceName = "Jaca ${Build.MODEL}"
            serviceType = SERVICE_TYPE
            setPort(port)
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo?) {}
            override fun onRegistrationFailed(info: NsdServiceInfo?, errorCode: Int) {}
            override fun onServiceUnregistered(info: NsdServiceInfo?) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo?, errorCode: Int) {}
        }
        regListener = listener
        runCatching { manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }
    }

    private fun unregisterNsd() {
        runCatching { regListener?.let { nsd?.unregisterService(it) } }
        regListener = null
        nsd = null
    }

    /// This device's LAN IPv4 (skips the VPN tun and loopback), for "connect by IP".
    fun deviceIp(): String? = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback && !it.name.startsWith("tun") }
            .flatMap { it.inetAddresses.toList() }
            .firstOrNull { it is Inet4Address && !it.isLoopbackAddress && it.isSiteLocalAddress }
            ?.hostAddress
    }.getOrNull()

    companion object {
        const val PORT = 8889
        const val SERVICE_TYPE = "_jaca._tcp."
        const val HEARTBEAT_MS = 3000L
        const val QUEUE_CAP = 2000
    }
}

/// Minimal JSON escaping for the line protocol (no serialization dependency needed).
private fun jsonStr(s: String): String {
    val sb = StringBuilder("\"")
    for (c in s) when (c) {
        '\\' -> sb.append("\\\\")
        '"' -> sb.append("\\\"")
        '\n' -> sb.append("\\n")
        '\r' -> sb.append("\\r")
        '\t' -> sb.append("\\t")
        else -> if (c < ' ') sb.append("\\u%04x".format(c.code)) else sb.append(c)
    }
    return sb.append("\"").toString()
}

/// One captured flow as a JSON line for the desktop stream.
fun flowJson(f: CapturedFlow): String =
    """{"type":"flow","app":${jsonStr(f.app)},"package":${jsonStr(f.packageName)},""" +
        """"host":${jsonStr(f.host)},"port":${f.port},"protocol":${jsonStr(f.protocol)}}"""
