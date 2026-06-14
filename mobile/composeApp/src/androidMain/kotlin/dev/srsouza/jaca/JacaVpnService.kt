package dev.srsouza.jaca

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import java.io.FileInputStream

/// M2 skeleton: establishes a tun, runs as a foreground service, and reads packets
/// off the tun (counting only — M3 adds TCP reassembly + per-app attribution, M4 the
/// on-device MITM). Excludes our own app from the VPN to avoid loops.
class JacaVpnService : VpnService() {
    private var tun: ParcelFileDescriptor? = null
    private var reader: Thread? = null
    @Volatile private var running = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
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
            .addAddress("10.0.0.2", 32)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("8.8.8.8")
        runCatching { builder.addDisallowedApplication(packageName) }
        val fd = builder.establish() ?: run { stopSelf(); return }
        tun = fd
        running = true
        VpnState.packets.value = 0
        VpnState.active.value = true
        reader = Thread {
            val input = FileInputStream(fd.fileDescriptor)
            val buffer = ByteArray(MTU)
            var count = 0L
            while (running) {
                val n = try { input.read(buffer) } catch (_: Exception) { break }
                if (n <= 0) { runCatching { Thread.sleep(2) }; continue }
                count++
                VpnState.packets.value = count
            }
        }.apply { name = "jaca-tun-reader"; start() }
    }

    override fun onDestroy() {
        running = false
        reader?.interrupt(); reader = null
        runCatching { tun?.close() }; tun = null
        VpnState.active.value = false
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Capture", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
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
        private const val MTU = 16384
    }
}
