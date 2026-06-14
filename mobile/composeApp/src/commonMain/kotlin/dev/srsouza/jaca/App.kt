package dev.srsouza.jaca

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeContentPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import com.teya.lemonade.Button
import com.teya.lemonade.ContentListItem
import com.teya.lemonade.LemonadeTheme
import com.teya.lemonade.LemonadeUi
import com.teya.lemonade.Notice
import com.teya.lemonade.Text
import com.teya.lemonade.core.LemonadeButtonVariant
import com.teya.lemonade.core.NoticeVoice

/// App entry — binds the shared UI to whatever capture engine the platform supplies.
@Composable
fun App(engine: CaptureEngine) {
    val state by engine.state.collectAsState()
    LemonadeTheme {
        CaptureScreen(
            state = state,
            supported = engine.isSupported,
            onToggle = engine::toggle,
            onInstallCa = engine::requestCaInstall,
            onRecheckCa = engine::recheckCa,
        )
    }
}

/// Companion UI — Jaca mobile captures on-device and streams to Jaca desktop, so the
/// phone only needs to show its address and whether the desktop is connected. Pure UI
/// (no platform types) so it renders the same on Android and iOS.
@Composable
fun CaptureScreen(
    state: CaptureState,
    supported: Boolean,
    onToggle: () -> Unit,
    onInstallCa: () -> Unit = {},
    onRecheckCa: () -> Unit = {},
) {
    val spaces = LemonadeTheme.spaces

    // Keep validating until the cert is actually trusted: while the install prompt is up,
    // poll the on-device trust store so the UI flips to "installed" the instant it's done.
    LaunchedEffect(state.caReceived, state.caTrusted) {
        if (state.caReceived && !state.caTrusted) {
            while (isActive) {
                delay(2000)
                onRecheckCa()
            }
        }
    }
    Column(
        Modifier
            .fillMaxSize()
            .background(LemonadeTheme.colors.background.bgDefault)
            .safeContentPadding()
            .padding(spaces.spacing400),
        verticalArrangement = Arrangement.spacedBy(spaces.spacing400),
    ) {
        LemonadeUi.Text("Jaca", textStyle = LemonadeTheme.typography.headingLarge)

        LemonadeUi.Text(
            text = if (state.active) "Capturing — ${state.packetCount} packets" else "Not capturing",
            textStyle = LemonadeTheme.typography.bodyMediumRegular,
            color = LemonadeTheme.colors.content.contentSecondary,
        )

        if (!supported) {
            LemonadeUi.Notice(
                content = "On-device capture is coming to iOS soon — the screen is already shared with Android.",
                voice = NoticeVoice.Info,
                title = "Not available on iOS yet",
            )
        }

        // HTTPS-decryption certificate setup — guided, and verified live by the poll above.
        if (supported) {
            CaSetup(state = state, onInstallCa = onInstallCa)
        }

        LemonadeUi.Button(
            label = if (state.active) "Stop capture" else "Start capture",
            onClick = onToggle,
            enabled = supported,
            variant = if (state.active) LemonadeButtonVariant.Critical else LemonadeButtonVariant.Primary,
            modifier = Modifier.fillMaxWidth(),
        )

        if (state.active) {
            LemonadeUi.Notice(
                content = "Open Jaca on your Mac. It finds this device automatically, or connect by the " +
                    "address below. No USB or ADB needed.",
                voice = NoticeVoice.Info,
                title = "Companion mode",
            )
            LemonadeUi.ContentListItem(
                label = "This device",
                value = state.serverAddress ?: "Resolving…",
                showDivider = false,
            )
            LemonadeUi.Notice(
                content = if (state.desktopConnected) {
                    "Connected to Jaca desktop — streaming captured traffic."
                } else {
                    "Waiting for Jaca desktop to connect…"
                },
                voice = if (state.desktopConnected) NoticeVoice.Positive else NoticeVoice.Neutral,
                title = if (state.desktopConnected) "Connected" else "Waiting",
            )
        }
    }
}

/// HTTPS-decryption certificate setup, mirroring the desktop's guided "manual" flow: clear
/// steps, one install action, a live "verifying" state that confirms automatically once the
/// cert becomes trusted, and a heads-up about a stale cert from a previous setup (which can't
/// be detected reliably). The desktop pushes the cert over the link — nothing to download.
@Composable
private fun CaSetup(
    state: CaptureState,
    onInstallCa: () -> Unit,
) {
    val spaces = LemonadeTheme.spaces
    when {
        state.caTrusted -> LemonadeUi.Notice(
            content = "The Jaca certificate is installed and trusted on this device. HTTPS traffic can be decrypted.",
            voice = NoticeVoice.Positive,
            title = "Certificate installed",
        )

        state.caReceived -> Column(
            verticalArrangement = Arrangement.spacedBy(spaces.spacing300),
        ) {
            LemonadeUi.Notice(
                content = "Your desktop sent its certificate over the link — nothing to download. " +
                    "To decrypt HTTPS:\n" +
                    "1.  Tap \"Install certificate\" below.\n" +
                    "2.  Confirm, and choose \"CA certificate\" if asked.\n" +
                    "Jaca keeps checking and confirms here automatically once it's trusted.",
                voice = NoticeVoice.Warning,
                title = "Install the Jaca certificate",
            )
            LemonadeUi.Button(
                label = "Install certificate",
                onClick = onInstallCa,
                variant = LemonadeButtonVariant.Primary,
                modifier = Modifier.fillMaxWidth(),
            )
            LemonadeUi.Notice(
                content = "Verifying automatically — this updates the moment the certificate is trusted.",
                voice = NoticeVoice.Neutral,
                title = "Checking…",
            )
            LemonadeUi.Notice(
                content = "Set Jaca up before? An older certificate may still be installed that doesn't " +
                    "match this desktop, and we can't detect that reliably. If HTTPS still won't decrypt, " +
                    "remove old Jaca certificates under Settings > Security > Encryption & credentials " +
                    "(Trusted credentials > User), then install this one again.",
                voice = NoticeVoice.Info,
                title = "Already set up before?",
            )
        }

        else -> LemonadeUi.Notice(
            content = if (state.desktopConnected) {
                "Desktop connected. Preparing the certificate to install…"
            } else {
                "Open Jaca on your Mac. It connects automatically and sends its certificate here so " +
                    "you can decrypt HTTPS — nothing to download."
            },
            voice = if (state.desktopConnected) NoticeVoice.Neutral else NoticeVoice.Info,
            title = "HTTPS decryption",
        )
    }
}
