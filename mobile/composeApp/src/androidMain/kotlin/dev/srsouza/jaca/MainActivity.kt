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
        val engine = AndroidCaptureEngine(applicationContext) { intent, onGranted ->
            onConsentGranted = onGranted
            vpnConsent.launch(intent)
        }
        setContent { App(engine) }
    }
}
