package dev.srsouza.jaca

import android.content.Context

/// Process-wide owner of the [DesktopBridge] gRPC server so it can run *before* capture.
/// The moment the app is open, the desktop — which learned this device's IP when it served
/// the APK — can connect to configure capture and push its CA for the user to install,
/// without the VPN running first.
///
/// Both the foreground Activity and the VpnService keep it alive via a ref count: the
/// Activity holds it while the app is on screen, the service holds it across a capture
/// session. So the link survives the app being backgrounded mid-capture, and survives the
/// capture service stopping while the app is still open.
object CompanionServer {
    private var bridge: DesktopBridge? = null
    private var refs = 0

    /// Start the server if needed and return the shared bridge, taking a ref.
    @Synchronized
    fun acquire(context: Context): DesktopBridge {
        val b = bridge ?: DesktopBridge(context.applicationContext).also {
            it.start()
            bridge = it
        }
        refs++
        return b
    }

    /// Drop a ref; stop the server once nothing holds it.
    @Synchronized
    fun release() {
        if (refs == 0) return
        refs--
        if (refs == 0) {
            bridge?.stop()
            bridge = null
        }
    }

    /// The running bridge, if any (e.g. to broadcast a captured flow).
    val current: DesktopBridge? @Synchronized get() = bridge
}
