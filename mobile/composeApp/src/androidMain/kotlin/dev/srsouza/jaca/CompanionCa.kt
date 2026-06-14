package dev.srsouza.jaca

import android.content.Context
import java.io.ByteArrayInputStream
import java.io.File
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Collections

/// On-device home for the desktop's HTTPS-decryption CA. The desktop pushes its cert over
/// the companion link (InstallCa) so the user never downloads it by hand; we persist it,
/// detect whether the user has actually trusted it (it appears in the system trust store),
/// and publish both facts to [VpnState] so the UI can prompt for the one manual install tap.
///
/// Detection note: this reports whether the cert is in the device trust store. Apps
/// targeting API 24+ only trust *system* CAs (or opt in via a network-security config), so a
/// user-store install covers browsers and opted-in apps; full coverage still needs the
/// desktop's rooted system-store path. The desktop's TLS handshake is the ground truth for
/// "decryption actually works" — this is the device-side signal that the user finished.
object CompanionCa {
    private const val FILE = "jaca-ca.pem"

    @Volatile
    var pem: ByteArray? = null
        private set

    @Volatile
    var name: String = "Jaca CA"
        private set

    @Volatile
    private var cert: X509Certificate? = null

    /// Load a previously received cert on app start so the UI shows real status on the first
    /// frame, even before the desktop reconnects.
    @Synchronized
    fun load(context: Context) {
        if (pem == null) {
            val f = File(context.filesDir, FILE)
            if (f.exists()) {
                pem = runCatching { f.readBytes() }.getOrNull()
                cert = pem?.let { parse(it) }
            }
        }
        refreshTrust()
    }

    /// Persist a cert pushed by the desktop and recompute trust. Idempotent.
    @Synchronized
    fun store(context: Context, pemBytes: ByteArray, certName: String) {
        pem = pemBytes
        name = certName.ifBlank { "Jaca CA" }
        cert = parse(pemBytes)
        runCatching { File(context.filesDir, FILE).writeBytes(pemBytes) }
        refreshTrust()
    }

    /// Re-check trust (call when returning from Settings) and publish it to the UI state.
    @Synchronized
    fun refreshTrust() {
        val trusted = cert?.let { isInDeviceTrustStore(it) } ?: false
        VpnState.setCa(received = pem != null, trusted = trusted, name = name)
    }

    private fun parse(bytes: ByteArray): X509Certificate? = runCatching {
        CertificateFactory.getInstance("X.509")
            .generateCertificate(ByteArrayInputStream(bytes)) as X509Certificate
    }.getOrNull()

    /// True when a cert matching ours is trusted on this device. "AndroidCAStore" unifies
    /// the system + user-added CA stores, so a user install (via Settings) shows up here.
    private fun isInDeviceTrustStore(target: X509Certificate): Boolean = runCatching {
        val ks = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
        if (ks.getCertificateAlias(target) != null) {
            true
        } else {
            Collections.list(ks.aliases()).any { alias ->
                val c = ks.getCertificate(alias) as? X509Certificate
                c != null &&
                    c.subjectX500Principal == target.subjectX500Principal &&
                    c.publicKey == target.publicKey
            }
        }
    }.getOrDefault(false)
}
