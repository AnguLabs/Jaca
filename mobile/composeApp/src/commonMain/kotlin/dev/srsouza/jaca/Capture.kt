package dev.srsouza.jaca

import kotlinx.coroutines.flow.StateFlow

/// Cross-platform snapshot of a capture session, rendered by the shared Compose UI.
/// Android fills this from a VpnService + getConnectionOwnerUid attribution; iOS will
/// fill it from a NetworkExtension provider later. Living in commonMain means both
/// platforms share the exact same model and screen.
data class CaptureState(
    val active: Boolean = false,
    val packetCount: Long = 0,
    val flows: List<CapturedFlow> = emptyList(),
    /// Address other Jaca desktops connect to (ip:port), shown in companion mode.
    val serverAddress: String? = null,
    /// Whether a Jaca desktop is currently connected and receiving the stream.
    val desktopConnected: Boolean = false,
    /// HTTPS-decryption certificate state, driven by the desktop pushing its CA over the
    /// link: whether we've received a cert to install, whether it's trusted on this device
    /// (detected from the system trust store), and its display name.
    val caReceived: Boolean = false,
    val caTrusted: Boolean = false,
    val caName: String = "Jaca CA",
)

/// The platform traffic-capture engine behind the shared UI. The UI only ever talks to
/// this interface, so adding iOS later means writing one more implementation — the
/// screen, state model and packet parsing are already shared.
interface CaptureEngine {
    /// Observable session state the UI collects.
    val state: StateFlow<CaptureState>

    /// Whether this platform can capture yet. iOS returns false until its
    /// NetworkExtension backend lands; the UI then shows a "coming soon" notice.
    val isSupported: Boolean

    /// Start capture when idle, stop it when running.
    fun toggle()

    /// Stage the desktop's CA (already received over the link) and open the system
    /// certificate-install flow — the single manual tap Android 11+ still requires. The
    /// cert is never downloaded by hand. No-op on platforms without on-device capture.
    fun requestCaInstall() {}

    /// Re-check whether the CA is trusted now. Called on a short timer while the install
    /// prompt is showing, so the UI flips to "installed" the moment the user finishes in
    /// Settings — no need to leave and re-enter the app. No-op where unsupported.
    fun recheckCa() {}
}

/// Newest-first flow history with consecutive-duplicate suppression and a hard cap.
/// Shared so every platform's engine keeps identical list semantics.
fun List<CapturedFlow>.withFlow(flow: CapturedFlow, cap: Int = 100): List<CapturedFlow> {
    if (firstOrNull() == flow) return this
    return (listOf(flow) + this).take(cap)
}
