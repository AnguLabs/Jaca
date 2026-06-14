package dev.srsouza.jaca

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeContentPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
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
) {
    val spaces = LemonadeTheme.spaces
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
