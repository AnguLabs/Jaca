package dev.srsouza.jaca

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/// iOS capture engine placeholder. On-device capture needs a NetworkExtension packet
/// tunnel provider (a separate app extension plus the Network Extensions entitlement),
/// which we'll add when iOS ships. Until then the shared UI renders with capture
/// disabled and shows a "coming soon" notice — every other feature is already shared.
class IosCaptureEngine : CaptureEngine {
    override val state: StateFlow<CaptureState> = MutableStateFlow(CaptureState())
    override val isSupported: Boolean = false
    override fun toggle() { /* no-op until the NetworkExtension backend exists */ }
}
