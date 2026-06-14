package dev.srsouza.jaca

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import dev.srsouza.jaca.vpn.IpHeader
import dev.srsouza.jaca.vpn.Protocol
import dev.srsouza.jaca.vpn.Session
import dev.srsouza.jaca.vpn.SessionProvider
import dev.srsouza.jaca.vpn.TcpForwarder
import dev.srsouza.jaca.vpn.TcpProxy
import dev.srsouza.jaca.vpn.UdpHeader
import dev.srsouza.jaca.vpn.UdpProxy
import dev.srsouza.jaca.vpn.intToIp
import dev.srsouza.jaca.vpn.ipToInt
import java.io.FileInputStream
import java.io.FileOutputStream

/// On-device capture engine. Establishes a tun, then forwards every packet through a
/// userspace relay so the device stays online: TCP connections are redirected to a local
/// proxy (kernel does TCP) and piped to protect()-ed upstream sockets; UDP is relayed per
/// flow. Each new connection is attributed to its app via getConnectionOwnerUid. The TLS
/// MITM layer (decrypting HTTPS) sits on top of this and lands next.
class JacaVpnService : VpnService() {
    private var tun: ParcelFileDescriptor? = null
    private var reader: Thread? = null
    @Volatile private var running = false
    private var tcpProxy: TcpProxy? = null
    private var udpProxy: UdpProxy? = null
    private var bridge: DesktopBridge? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            running = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(NOTIF_ID, buildNotification())
        startTun()
        return START_STICKY
    }

    private fun startTun() {
        if (running) return
        val builder = Builder()
            .setSession("Jaca")
            .setMtu(MTU)
            .addAddress(TUN_ADDRESS, 32)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("8.8.8.8")
            .setBlocking(true)
        runCatching { builder.addDisallowedApplication(packageName) }
        val fd = builder.establish() ?: run { stopSelf(); return }
        tun = fd
        running = true
        VpnState.start()

        val input = FileInputStream(fd.fileDescriptor)
        val output = FileOutputStream(fd.fileDescriptor)
        val writeLock = Any()
        val sessions = SessionProvider()
        val attributor = FlowAttributor(this)

        // Companion link to Jaca desktop: advertise over mDNS + stream captured flows.
        val db = DesktopBridge(applicationContext) { connected ->
            VpnState.setDesktopConnected(connected)
            if (!connected) tcpProxy?.tunnel = null   // desktop gone: fall back to direct, stay online
        }
        db.start()
        bridge = db
        VpnState.setServerAddress(db.deviceIp()?.let { "$it:${db.port}" })

        // Attribute each new connection once (off the hot path), then stream it to desktop.
        val onSession: (Session) -> Unit = { session ->
            if (!session.attributed) {
                session.attributed = true
                val flow = Flow(
                    protocol = session.protocol.number.toInt(),
                    srcIp = TUN_ADDRESS,
                    srcPort = session.localPort.toInt() and 0xFFFF,
                    dstIp = intToIp(session.remoteIp),
                    dstPort = session.remotePort.toInt() and 0xFFFF,
                )
                attributor.attribute(flow)?.let {
                    session.packageName = it.packageName   // sent to the desktop proxy as X-Jaca-App
                    VpnState.addFlow(it)
                    db.broadcast(flowJson(it))
                }
            }
        }

        val tcp = TcpProxy(this, sessions).also { it.start() }
        val udp = UdpProxy(this, sessions, output, writeLock, onSession).also { it.start() }
        tcpProxy = tcp
        udpProxy = udp
        // When the desktop advertises its decryption proxy, tunnel TLS connections there.
        db.onProxy = { host, port -> tcpProxy?.tunnel = java.net.InetSocketAddress(host, port) }
        val tcpForwarder = TcpForwarder(ipToInt(TUN_ADDRESS), tcp.port, sessions, output, writeLock, onSession)

        reader = Thread({
            val buffer = ByteArray(MTU)
            var count = 0L
            while (running) {
                val n = try { input.read(buffer) } catch (_: Exception) { break }
                if (n <= 0) continue
                count++
                VpnState.setPackets(count)
                val ip = IpHeader(buffer, 0)
                if (ip.version() != 4) continue
                when (Protocol.parse(ip.getProtocol().toInt() and 0xFF)) {
                    Protocol.TCP -> tcpForwarder.forward(buffer, n)
                    Protocol.UDP -> udp.send(UdpHeader(ip, buffer, ip.getHeaderLength()))
                    else -> { /* drop ICMP / unsupported */ }
                }
            }
        }, "jaca-tun-reader").apply { start() }
    }

    override fun onDestroy() {
        running = false
        reader?.interrupt(); reader = null
        tcpProxy?.stop(); tcpProxy = null
        udpProxy?.stop(); udpProxy = null
        bridge?.stop(); bridge = null
        runCatching { tun?.close() }; tun = null
        VpnState.stop()
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Capture", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL)
            .setContentTitle("Jaca capture active")
            .setContentText("Inspecting network traffic")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val ACTION_STOP = "dev.srsouza.jaca.STOP"
        private const val NOTIF_ID = 1
        private const val CHANNEL = "jaca_vpn"
        private const val MTU = 4096
        private const val TUN_ADDRESS = "10.0.0.2"
    }
}
