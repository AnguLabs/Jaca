package dev.srsouza.jaca

import kotlinx.coroutines.flow.MutableStateFlow

/// Process-wide capture state the VpnService updates and the UI observes.
object VpnState {
    val active = MutableStateFlow(false)
    val packets = MutableStateFlow(0L)
}
