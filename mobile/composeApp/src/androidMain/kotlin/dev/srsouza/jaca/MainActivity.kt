package dev.srsouza.jaca

import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue

class MainActivity : ComponentActivity() {
    private val vpnConsent = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == RESULT_OK) startVpn()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val active by VpnState.active.collectAsState()
            val packets by VpnState.packets.collectAsState()
            App(
                vpnActive = active,
                packetCount = packets,
                onToggleVpn = { if (active) stopVpn() else requestVpn() }
            )
        }
    }

    /// Asks for VPN consent the first time, then starts the service.
    private fun requestVpn() {
        val intent = VpnService.prepare(this)
        if (intent != null) vpnConsent.launch(intent) else startVpn()
    }

    private fun startVpn() {
        startForegroundService(Intent(this, JacaVpnService::class.java))
    }

    private fun stopVpn() {
        startService(Intent(this, JacaVpnService::class.java).setAction(JacaVpnService.ACTION_STOP))
    }
}
