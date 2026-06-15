package dev.srsouza.jaca

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import dev.srsouza.jaca.grpc.Ack
import dev.srsouza.jaca.grpc.CaCert
import dev.srsouza.jaca.grpc.CaptureMode
import dev.srsouza.jaca.grpc.CompanionGrpc
import dev.srsouza.jaca.grpc.DeviceInfo
import dev.srsouza.jaca.grpc.Empty
import dev.srsouza.jaca.grpc.FlowMeta
import dev.srsouza.jaca.grpc.ProxyConfig
import io.grpc.Server
import io.grpc.ServerCredentials
import io.grpc.TlsServerCredentials
import io.grpc.okhttp.OkHttpServerBuilder
import io.grpc.stub.ServerCallStreamObserver
import io.grpc.stub.StreamObserver
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Collections
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/// The companion link to Jaca desktop, served over gRPC (HTTP/2) with TLS. Advertises
/// this device over mDNS (so the desktop finds it with no ADB), then:
///  - `StreamFlows`: streams captured flow metadata to each connected desktop. The stream
///    staying open is also the liveness signal — when it ends the phone clears the
///    decryption tunnel and falls back to direct so the device stays online.
///  - `SetProxy`: the desktop tells the phone where its decryption proxy is (decryption
///    stays on the desktop; no CA key here).
///  - `Describe`: device self-info for the desktop's device list.
///
/// Each flow subscriber gets its OWN bounded queue + writer thread, so [broadcast] (called
/// from the capture/tun thread) only ever does a non-blocking enqueue. A dead or stalled
/// desktop can never block packet forwarding — it just gets pruned. gRPC's HTTP/2
/// keepalive detects dead connections, replacing the old hand-rolled heartbeat.
class DesktopBridge(
    private val context: Context,
) {
    /// Data-plane hook set by the capture service: called with (host, port) when the desktop
    /// advertises its decryption proxy, and with (null, 0) when the desktop disconnects so
    /// the tunnel is torn down and the device stays online. Null before capture starts — the
    /// control plane (Describe / InstallCa / flow stream) runs regardless, so the desktop can
    /// push and the user can install the CA before any capture.
    var onProxyChanged: ((String?, Int) -> Unit)? = null

    private val subscribers = Collections.synchronizedList(mutableListOf<FlowSubscriber>())
    private var server: Server? = null
    private var nsd: NsdManager? = null
    private var regListener: NsdManager.RegistrationListener? = null
    @Volatile private var running = false
    var port: Int = PORT
        private set

    private val service = object : CompanionGrpc.CompanionImplBase() {
        override fun streamFlows(request: Empty, responseObserver: StreamObserver<FlowMeta>) {
            @Suppress("UNCHECKED_CAST")
            val sco = responseObserver as ServerCallStreamObserver<FlowMeta>
            val sub = FlowSubscriber(sco)
            subscribers.add(sub)
            sub.start()
        }

        override fun setProxy(request: ProxyConfig, responseObserver: StreamObserver<Ack>) {
            onProxyChanged?.invoke(request.host, request.port)
            responseObserver.onNext(Ack.getDefaultInstance())
            responseObserver.onCompleted()
        }

        override fun describe(request: Empty, responseObserver: StreamObserver<DeviceInfo>) {
            responseObserver.onNext(
                DeviceInfo.newBuilder()
                    .setName("Jaca ${Build.MODEL}")
                    .setDeviceIp(deviceIp().orEmpty())
                    .setMode(CaptureMode.STREAM_FULL)
                    .setVersion(BuildConfig.COMMIT_HASH)
                    .build(),
            )
            responseObserver.onCompleted()
        }

        override fun installCa(request: CaCert, responseObserver: StreamObserver<Ack>) {
            // The desktop pushes its CA over the link. We persist it and detect whether it's
            // already trusted; the app then surfaces a single "Install certificate" prompt
            // that opens the system flow (the one manual tap Android 11+ still requires).
            // Nothing is downloaded by hand and Settings is never opened unprompted.
            CompanionCa.store(context, request.pem.toByteArray(), request.name)
            responseObserver.onNext(Ack.getDefaultInstance())
            responseObserver.onCompleted()
        }
    }

    fun start() {
        running = true
        // TLS so the link is encrypted on the LAN (the phone is the TLS server, key in the
        // AndroidKeyStore). Falls back to a fresh port if 8889 is taken.
        val creds = TlsServerCredentials.newBuilder().keyManager(*CompanionTls.keyManagers()).build()
        val srv = runCatching { buildServer(PORT, creds) }
            .getOrElse { buildServer(0, creds) }
        server = srv
        port = srv.port
        registerNsd(port)
    }

    private fun buildServer(port: Int, creds: ServerCredentials): Server =
        OkHttpServerBuilder.forPort(port, creds)
            .addService(service)
            // HTTP/2 keepalive: ping idle desktops; drop the connection (and its stream)
            // if they stop answering, so a dead desktop is detected and the tunnel cleared.
            .keepAliveTime(KEEPALIVE_MS, TimeUnit.MILLISECONDS)
            .keepAliveTimeout(KEEPALIVE_MS, TimeUnit.MILLISECONDS)
            .permitKeepAliveWithoutCalls(true)
            .permitKeepAliveTime(1, TimeUnit.SECONDS)
            .build()
            .start()

    fun stop() {
        running = false
        unregisterNsd()
        synchronized(subscribers) { subscribers.toList().forEach { it.die() } }
        runCatching { server?.shutdownNow() }
        server = null
        VpnState.setDesktopConnected(false)
        onProxyChanged?.invoke(null, 0)
    }

    /// Non-blocking: enqueues one FlowMeta per connected desktop. Safe to call from the
    /// capture thread because no socket I/O happens here.
    fun broadcast(flow: CapturedFlow) {
        val meta = FlowMeta.newBuilder()
            .setId("${flow.protocol}|${flow.host}:${flow.port}")
            .setApp(flow.app)
            .setPackageName(flow.packageName)
            .setHost(flow.host)
            .setPort(flow.port)
            .setProtocol(flow.protocol)
            .setStartedAtMs(System.currentTimeMillis())
            .build()
        synchronized(subscribers) { subscribers.forEach { it.enqueue(meta) } }
    }

    /// One connected desktop's flow stream: a bounded queue drained by a dedicated writer
    /// thread. The writer owns all `onNext` calls; the capture thread only enqueues.
    private inner class FlowSubscriber(private val observer: ServerCallStreamObserver<FlowMeta>) {
        private val queue = LinkedBlockingQueue<FlowMeta>(QUEUE_CAP)
        @Volatile private var alive = true
        private val writer = Thread({ writeLoop() }, "jaca-grpc-writer")

        fun start() {
            observer.setOnCancelHandler { die() } // desktop disconnected / cancelled
            writer.start()
            VpnState.setDesktopConnected(true)
        }

        fun enqueue(meta: FlowMeta) {
            if (!alive) return
            if (!queue.offer(meta)) { queue.poll(); queue.offer(meta) } // drop oldest if backed up
        }

        private fun writeLoop() {
            while (alive) {
                val meta = try { queue.poll(2, TimeUnit.SECONDS) } catch (_: InterruptedException) { break } ?: continue
                try {
                    if (observer.isReady) observer.onNext(meta) // honor flow control; else drop
                } catch (_: Exception) { return die() }
            }
        }

        fun die() {
            if (!alive) return
            alive = false
            writer.interrupt()
            subscribers.remove(this)
            runCatching { observer.onCompleted() }
            val stillConnected = subscribers.isNotEmpty()
            VpnState.setDesktopConnected(stillConnected)
            if (!stillConnected) onProxyChanged?.invoke(null, 0) // back to direct; device stays online
        }
    }

    private fun registerNsd(port: Int) {
        val manager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager ?: return
        nsd = manager
        val info = NsdServiceInfo().apply {
            serviceName = "Jaca ${Build.MODEL}"
            serviceType = SERVICE_TYPE
            setPort(port)
            // Stable device identity so the desktop keys this device by id, not its IP, and
            // shows one entry that survives address changes across Wi-Fi reconnects.
            setAttribute("id", CompanionId.get(context))
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
        const val KEEPALIVE_MS = 5000L
        const val QUEUE_CAP = 2000
    }
}
