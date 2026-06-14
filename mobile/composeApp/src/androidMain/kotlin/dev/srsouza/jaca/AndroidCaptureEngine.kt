package dev.srsouza.jaca

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.provider.MediaStore
import android.provider.Settings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/// Android capture engine: a VpnService captures the tun and getConnectionOwnerUid
/// attributes each flow to an app. Starting needs one-time VPN consent, which only an
/// Activity can request — [requestConsent] hands the system intent back to the Activity,
/// which launches it and calls `onGranted` on approval.
class AndroidCaptureEngine(
    private val context: Context,
    private val requestConsent: (intent: Intent, onGranted: () -> Unit) -> Unit,
) : CaptureEngine {
    override val state: StateFlow<CaptureState> = VpnState.state
    override val isSupported: Boolean = true

    /// Background scope for the trust re-check (reads the system trust store off-main).
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    override fun recheckCa() {
        scope.launch { CompanionCa.refreshTrust() }
    }

    override fun toggle() {
        if (state.value.active) stop() else start()
    }

    /// Stage the desktop's CA (already received over the link) into Downloads so it's
    /// pickable, then open Security settings for the one manual tap: Encryption & credentials
    /// > Install a certificate > CA certificate. Android 11+ blocks a fully automatic,
    /// all-apps install on non-rooted devices — this is the closest no-download path.
    override fun requestCaInstall() {
        val pem = CompanionCa.pem ?: return
        runCatching {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, "Jaca-CA.crt")
                put(MediaStore.Downloads.MIME_TYPE, "application/x-x509-ca-cert")
            }
            val resolver = context.contentResolver
            resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)?.let { uri ->
                resolver.openOutputStream(uri)?.use { it.write(pem) }
            }
            context.startActivity(
                Intent(Settings.ACTION_SECURITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    private fun start() {
        val consent = VpnService.prepare(context)
        if (consent == null) launchService() else requestConsent(consent) { launchService() }
    }

    private fun launchService() {
        context.startForegroundService(Intent(context, JacaVpnService::class.java))
    }

    private fun stop() {
        context.startService(
            Intent(context, JacaVpnService::class.java).setAction(JacaVpnService.ACTION_STOP),
        )
    }
}
