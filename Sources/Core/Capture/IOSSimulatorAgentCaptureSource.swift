import Foundation

/// In-process agent capture for a debug app on the iOS **Simulator** — the iOS counterpart of
/// `AgentCaptureSource`. Wraps `IOSSimulatorAgentController`, which injects the bundled
/// `JacaNetAgent` dylib via `simctl launch` + `DYLD_INSERT_LIBRARIES` and streams the agent's
/// JSON through the shared `AgentTransactionParser`. No proxy, no CA.
@MainActor
final class IOSSimulatorAgentCaptureSource: CaptureSource {
    private let device: Device
    private let bundleID: String
    private var controller: IOSSimulatorAgentController?

    init(device: Device, bundleID: String) {
        self.device = device
        self.bundleID = bundleID
    }

    func start(into sink: CaptureSink) {
        guard !bundleID.isEmpty, let dylib = AgentArtifacts.iosNetworkAgentURL else {
            sink.capture(didChangeStatus: AgentArtifacts.iosMissingMessage)
            return
        }
        let controller = IOSSimulatorAgentController(
            udid: device.id, bundleID: bundleID, agentDylib: dylib,
            onTransaction: { [weak sink] txn in Task { @MainActor in sink?.capture(didReceive: txn) } },
            onStatus: { [weak sink] s in Task { @MainActor in sink?.capture(didChangeStatus: s) } },
        )
        self.controller = controller
        controller.start()
    }

    func stop() { controller?.stop(); controller = nil }

    /// Readiness (the descriptor's precheck): the agent dylib must be bundled, the simulator
    /// booted, and an app chosen. Returns a clear message to abort, or nil when ready.
    static func precheck(device: Device, bundleID: String?) async -> String? {
        guard AgentArtifacts.iosNetworkAgentAvailable else { return AgentArtifacts.iosMissingMessage }
        let r = try? await CommandRunner.run(AppleToolchain.xcrun, ["simctl", "list", "devices", "booted"])
        guard r?.stdout.contains(device.id) ?? false else {
            return "\(device.displayModel) isn’t booted — start the simulator and try again."
        }
        guard let id = bundleID, !id.isEmpty else { return "Pick an app to inspect on \(device.displayModel)." }
        return nil
    }
}
