package dev.srsouza.jaca

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

/// Process-wide capture state the VpnService writes and the UI observes. The service and
/// Activity run in the same process, so a singleton [StateFlow] is the simplest bridge.
object VpnState {
    val state = MutableStateFlow(CaptureState())

    /// Begin a fresh session (clears the previous run's packets/flows).
    fun start() { state.value = CaptureState(active = true) }

    /// Mark capture stopped but keep the collected flows on screen.
    fun stop() { state.update { it.copy(active = false) } }

    fun setPackets(count: Long) { state.update { it.copy(packetCount = count) } }

    fun addFlow(flow: CapturedFlow) { state.update { it.copy(flows = it.flows.withFlow(flow)) } }

    fun setServerAddress(address: String?) { state.update { it.copy(serverAddress = address) } }

    fun setDesktopConnected(connected: Boolean) { state.update { it.copy(desktopConnected = connected) } }

    /// CA state from [CompanionCa]: whether a cert was received and whether it's trusted
    /// on this device. Drives the in-app "install certificate" prompt.
    fun setCa(received: Boolean, trusted: Boolean, name: String) {
        state.update { it.copy(caReceived = received, caTrusted = trusted, caName = name) }
    }
}
