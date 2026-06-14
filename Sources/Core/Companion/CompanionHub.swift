import Foundation
import Network

/// Shared companion plumbing: one mDNS browse + many device connections, with per-device
/// flow subscriptions. AppModel owns one hub; the device list reads discovery + connection
/// state from it, a `CompanionCaptureSource` subscribes to a single device's flows, and QR
/// onboarding registers a manual endpoint (by IP) that the hub keeps trying to reach.
@MainActor
final class CompanionHub {
    private let link = CompanionLink()
    private var flowHandlers: [String: (CompanionFlow) -> Void] = [:]
    private var mdns: [String: CompanionDevice] = [:]
    private var manual: [String: CompanionDevice] = [:]
    private var browsing = false

    /// Union of mDNS + manual devices, whenever it changes.
    var onDevices: (([CompanionDevice]) -> Void)?
    /// (deviceID, connected) as streams open and close.
    var onConnectionChange: ((String, Bool) -> Void)?
    /// Device ids with a live stream right now.
    private(set) var connected: Set<String> = []

    init() {
        link.onDevices = { [weak self] devices in
            Task { @MainActor in
                guard let self else { return }
                self.mdns = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                self.emitDevices()
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
    /// Connect using the endpoint known for this id (mDNS or a remembered manual one).
    func connect(id: String) {
        if let endpoint = manual[id]?.endpoint ?? mdns[id]?.endpoint { link.connect(id: id, to: endpoint) }
    }
    func disconnect(id: String) { link.disconnect(id: id) }

    func subscribe(id: String, _ handler: @escaping (CompanionFlow) -> Void) { flowHandlers[id] = handler }
    func unsubscribe(id: String) { flowHandlers[id] = nil }
    /// Send a control line to a connected device (e.g. the decryption proxy address).
    func send(id: String, line: String) { link.send(id: id, line: line) }

    /// Remember a device by IP (from QR onboarding) and keep trying to reach it, so it
    /// shows up in the device list and connects automatically once its app is running.
    func rememberManual(host: String, port: UInt16 = 8889, name: String? = nil) {
        let id = "\(host):\(port)"
        if manual[id] == nil, let p = NWEndpoint.Port(rawValue: port) {
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: p)
            manual[id] = CompanionDevice(id: id, name: name ?? host, endpoint: endpoint)
            emitDevices()
        }
        retryConnect(id: id)
    }

    private func retryConnect(id: String) {
        Task { @MainActor in
            for _ in 0..<40 {
                if connected.contains(id) { return }
                connect(id: id)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func emitDevices() { onDevices?(Array(mdns.values) + Array(manual.values)) }

    private func handleConnection(_ id: String, _ isConnected: Bool) {
        if isConnected { connected.insert(id) } else { connected.remove(id) }
        onConnectionChange?(id, isConnected)
    }
}
