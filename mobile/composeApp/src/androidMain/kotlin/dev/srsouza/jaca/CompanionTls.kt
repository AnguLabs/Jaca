package dev.srsouza.jaca

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.util.Date
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocketFactory
import javax.security.auth.x500.X500Principal

/// TLS for the companion stream so the desktop↔device link is encrypted on the LAN and
/// can't be passively traced. The phone is the TLS server; its key + self-signed cert
/// live in the AndroidKeyStore (no extra crypto dependency, key non-exportable). The
/// desktop trusts it without PKI — the goal is confidentiality of the link, and the CA
/// the desktop installs is what actually authenticates decrypted app traffic.
///
/// The key is **EC P-256**, not RSA: Conscrypt's TLS stack drives an AndroidKeyStore EC
/// key natively (ECDHE_ECDSA), whereas a keystore RSA key trips the software upcall path
/// and fails with INCOMPATIBLE_PADDING_MODE (TLS wants raw/PSS RSA, the key only allows
/// what KeyGenParameterSpec authorized).
object CompanionTls {
    private const val ALIAS = "jaca-companion-ec2"

    fun serverSocketFactory(): SSLServerSocketFactory {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        // Purge stale Jaca keys: the X509 KeyManager serves EVERY key in the store, so a
        // leftover alias from an older config (e.g. wrong digest/padding) can get picked
        // during the handshake and fail. Keep only the current one.
        keyStore.aliases().toList()
            .filter { it.startsWith("jaca-companion") && it != ALIAS }
            .forEach { runCatching { keyStore.deleteEntry(it) } }
        if (!keyStore.containsAlias(ALIAS)) generateKey()
        val kmf = KeyManagerFactory.getInstance("X509").apply { init(keyStore, null) }
        val ctx = SSLContext.getInstance("TLS").apply { init(kmf.keyManagers, null, null) }
        return ctx.serverSocketFactory
    }

    private fun generateKey() {
        val kpg = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        kpg.initialize(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                .setDigests(
                    // NONE is required: Conscrypt's TLS stack hashes in software and asks
                    // the keystore for a raw ECDSA sign over the pre-hashed handshake.
                    KeyProperties.DIGEST_NONE,
                    KeyProperties.DIGEST_SHA256,
                    KeyProperties.DIGEST_SHA384,
                    KeyProperties.DIGEST_SHA512,
                )
                .setCertificateSubject(X500Principal("CN=Jaca Companion"))
                .setCertificateNotBefore(Date(0))
                .build(),
        )
        kpg.generateKeyPair()
    }
}
