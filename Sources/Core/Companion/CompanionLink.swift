import Foundation
import Network

/// One captured flow received from a Jaca mobile device over the companion stream.
struct CompanionFlow: Identifiable, Hashable, Sendable {
    let id = UUID()
    let app: String
    let packageName: String
    let host: String
    let port: Int
    let proto: String
    var deviceName: String = ""
}

/// A Jaca mobile device discovered on the LAN via mDNS (`_jaca._tcp`).
struct CompanionDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

/// mDNS discovery + TCP clients for Jaca mobile devices. Supports MANY simultaneous
/// connections (one per device); each delivers newline-delimited JSON tagged with the
/// device id. Uses Network.framework; all state lives on a private serial queue and
/// results are delivered via callbacks the model hops to the main actor.
final class CompanionLink {
    var onDevices: (([CompanionDevice]) -> Void)?
    var onConnected: ((String, Bool) -> Void)?
    var onFlow: ((String, CompanionFlow) -> Void)?

    private let queue = DispatchQueue(label: "dev.srsouza.jaca.companion")
    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]
    private var buffers: [String: Data] = [:]

    func startBrowsing() {
        queue.async {
            guard self.browser == nil else { return }
            let browser = NWBrowser(for: .bonjour(type: "_jaca._tcp", domain: nil), using: NWParameters())
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let devices = results.map { result -> CompanionDevice in
                    let name: String
                    if case let .service(svcName, _, _, _) = result.endpoint { name = svcName } else { name = "\(result.endpoint)" }
                    return CompanionDevice(id: "\(result.endpoint)", name: name, endpoint: result.endpoint)
                }
                self?.onDevices?(devices.sorted { $0.name < $1.name })
            }
            browser.start(queue: self.queue)
            self.browser = browser
        }
    }

    func connect(id: String, to endpoint: NWEndpoint) {
        queue.async {
            self.connections[id]?.cancel()
            self.buffers[id] = Data()
            let conn = NWConnection(to: endpoint, using: .tcp)
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.onConnected?(id, true); self.receive(id: id)
                case .failed, .cancelled: self.cleanup(id); self.onConnected?(id, false)
                default: break
                }
            }
            self.connections[id] = conn
            conn.start(queue: self.queue)
        }
    }

    func connect(id: String, host: String, port: UInt16) {
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        connect(id: id, to: .hostPort(host: NWEndpoint.Host(host), port: p))
    }

    func disconnect(id: String) {
        queue.async {
            self.connections[id]?.cancel()
            self.cleanup(id)
            self.onConnected?(id, false)
        }
    }

    private func cleanup(_ id: String) { connections[id] = nil; buffers[id] = nil }

    private func receive(id: String) {
        connections[id]?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffers[id, default: Data()].append(data); self.drain(id) }
            if isComplete || error != nil { self.cleanup(id); self.onConnected?(id, false); return }
            self.receive(id: id)
        }
    }

    private func drain(_ id: String) {
        guard var buf = buffers[id] else { return }
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf.subdata(in: buf.startIndex..<nl)
            buf.removeSubrange(buf.startIndex...nl)
            if !line.isEmpty, let flow = Self.parse(line) { onFlow?(id, flow) }
        }
        buffers[id] = buf
    }

    private struct FlowLine: Decodable {
        let type: String; let app: String; let package: String
        let host: String; let port: Int; let `protocol`: String
    }

    private static func parse(_ data: Data) -> CompanionFlow? {
        guard let line = try? JSONDecoder().decode(FlowLine.self, from: data), line.type == "flow" else { return nil }
        return CompanionFlow(app: line.app, packageName: line.package, host: line.host, port: line.port, proto: line.protocol)
    }
}
