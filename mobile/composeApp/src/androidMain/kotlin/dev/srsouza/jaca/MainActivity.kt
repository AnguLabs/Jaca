package dev.srsouza.jaca

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts

class MainActivity : ComponentActivity() {
    /// Set when capture is requested and VPN consent is needed; invoked on approval.
    private var onConsentGranted: (() -> Unit)? = null

    private val vpnConsent = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (result.resultCode == RESULT_OK) onConsentGranted?.invoke()
        onConsentGranted = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Show real CA status on the first frame, and start the companion gRPC server now —
        // before any capture — so the desktop (which learned this device's IP when it served
        // the APK) can connect, push its certificate, and configure capture automatically.
        CompanionCa.load(applicationContext)
        CompanionServer.acquire(applicationContext)
        val engine = AndroidCaptureEngine(applicationContext) { intent, onGranted ->
            onConsentGranted = onGranted
            vpnConsent.launch(intent)
        }
        setContent { App(engine) }
    }

    override fun onResume() {
        super.onResume()
        // Re-check trust when returning to the app, e.g. right after installing the cert in
        // Settings, so the prompt flips to "installed" without needing the desktop.
        CompanionCa.refreshTrust()
    }

    override fun onDestroy() {
        // Drop our hold on the shared server (the capture service may still keep it alive).
        CompanionServer.release()
        super.onDestroy()
    }
}
