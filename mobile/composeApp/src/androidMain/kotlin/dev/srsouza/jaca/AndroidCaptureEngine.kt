package dev.srsouza.jaca

import android.content.Context
import android.content.Intent
import android.net.VpnService
import kotlinx.coroutines.flow.StateFlow

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

    override fun toggle() {
        if (state.value.active) stop() else start()
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
