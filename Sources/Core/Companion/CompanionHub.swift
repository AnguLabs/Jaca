import Foundation
import Network

/// Shared companion plumbing: one mDNS browse + many device connections, with per-device
/// flow subscriptions. AppModel owns one hub; the device list reads discovery + connection
/// state from it, and a `CompanionCaptureSource` subscribes to a single device's flows.
@MainActor
final class CompanionHub {
    private let link = CompanionLink()
    private var flowHandlers: [String: (CompanionFlow) -> Void] = [:]
    private var discovered: [String: CompanionDevice] = [:]
    private var browsing = false

    /// Latest mDNS discovery results.
    var onDevices: (([CompanionDevice]) -> Void)?
    /// (deviceID, connected) as streams open and close.
    var onConnectionChange: ((String, Bool) -> Void)?
    /// Device ids with a live stream right now.
    private(set) var connected: Set<String> = []

    init() {
        link.onDevices = { [weak self] devices in
            Task { @MainActor in
                guard let self else { return }
                for d in devices { self.discovered[d.id] = d }
                self.onDevices?(devices)
            }
        }
        link.onConnected = { [weak self] id, c in Task { @MainActor in self?.handleConnection(id, c) } }
        link.onFlow = { [weak self] id, flow in Task { @MainActor in self?.flowHandlers[id]?(flow) } }
    }

    func startBrowsing() {
        guard !browsing else { return }
        browsing = true
        link.startBrowsing()
    }

    func connect(id: String, to endpoint: NWEndpoint) { link.connect(id: id, to: endpoint) }
    func connect(id: String, host: String, port: UInt16) { link.connect(id: id, host: host, port: port) }
    /// Connect using the endpoint discovered for this id (falls back to host:port if the
    /// id looks like "host:port", e.g. a manual connect-by-IP).
    func connect(id: String) {
        if let endpoint = discovered[id]?.endpoint { link.connect(id: id, to: endpoint) }
    }
    func disconnect(id: String) { link.disconnect(id: id) }

    func subscribe(id: String, _ handler: @escaping (CompanionFlow) -> Void) { flowHandlers[id] = handler }
    func unsubscribe(id: String) { flowHandlers[id] = nil }

    private func handleConnection(_ id: String, _ isConnected: Bool) {
        if isConnected { connected.insert(id) } else { connected.remove(id) }
        onConnectionChange?(id, isConnected)
    }
}
