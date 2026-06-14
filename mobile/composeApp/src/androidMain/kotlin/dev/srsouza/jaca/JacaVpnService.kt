package dev.srsouza.jaca

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/// On-device capture engine. Establishes a tun, then hands the tun fd to a native userspace
/// TCP/IP relay (zdtun) so the device stays online: zdtun terminates each connection in
/// userspace and forwards it to a protect()-ed upstream socket (its traffic bypasses the
/// VPN). Unlike the old kernel-redirect relay, this needs no local listening socket, so it
/// works on the Android emulator as well as real devices. Each new connection is reported
/// back here for per-app attribution (getConnectionOwnerUid) and streamed to the desktop.
class JacaVpnService : VpnService() {
    private var tun: ParcelFileDescriptor? = null
    @Volatile private var running = false
    private var captureThread: Thread? = null
    private var attribThread: Thread? = null
    private var bridge: DesktopBridge? = null
    private var attributor: FlowAttributor? = null
    private val attribQueue = LinkedBlockingQueue<Flow>(ATTRIB_CAP)

    private external fun nativeRun(tunFd: Int, sdk: Int)
    private external fun nativeStop()

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

        attributor = FlowAttributor(this)

        // Companion link to Jaca desktop: advertise over mDNS + stream captured flows.
        val db = DesktopBridge(applicationContext) { connected -> VpnState.setDesktopConnected(connected) }
        db.start()
        bridge = db
        VpnState.setServerAddress(db.deviceIp()?.let { "$it:${db.port}" })

        // Attribution worker: getConnectionOwnerUid off the capture thread so connection
        // setup never stalls. Each new connection is attributed once and streamed out.
        attribThread = Thread({
            while (running) {
                val flow = try { attribQueue.poll(1, TimeUnit.SECONDS) } catch (_: InterruptedException) { break } ?: continue
                attributor?.attribute(flow)?.let {
                    VpnState.addFlow(it)
                    bridge?.broadcast(it)
                }
            }
        }, "jaca-attrib").apply { start() }

        // Native userspace capture loop reads/writes the tun fd directly.
        val tunFd = fd.fd
        captureThread = Thread({ nativeRun(tunFd, Build.VERSION.SDK_INT) }, "jaca-capture").apply { start() }
    }

    /// Called from native (JNI) for every new upstream socket — protect it so its traffic
    /// bypasses the VPN and the device stays online.
    @Suppress("unused")
    fun protectFd(fd: Int): Boolean = protect(fd)

    /// Called from native (JNI) for every new connection — enqueue for attribution.
    @Suppress("unused")
    fun onConnection(proto: Int, srcIp: String, srcPort: Int, dstIp: String, dstPort: Int) {
        attribQueue.offer(Flow(protocol = proto, srcIp = srcIp, srcPort = srcPort, dstIp = dstIp, dstPort = dstPort))
    }

    override fun onDestroy() {
        running = false
        runCatching { nativeStop() }
        attribThread?.interrupt(); attribThread = null
        captureThread?.interrupt(); captureThread = null
        bridge?.stop(); bridge = null
        runCatching { tun?.close() }; tun = null   // unblocks the native tun read
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
        init { System.loadLibrary("jacacapture") }
        const val ACTION_STOP = "dev.srsouza.jaca.STOP"
        private const val NOTIF_ID = 1
        private const val CHANNEL = "jaca_vpn"
        private const val MTU = 4096
        private const val TUN_ADDRESS = "10.0.0.2"
        private const val ATTRIB_CAP = 1000
    }
}
