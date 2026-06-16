import Foundation
import GRPC
import NIOCore
import NIOPosix
import NIOSSL
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

/// mDNS discovery + gRPC clients for Jaca mobile devices. Supports MANY simultaneous
/// connections (one per device); each opens a TLS gRPC channel to the phone's Companion
/// service and runs a server-streaming `StreamFlows` call. The channel's connectivity
/// state drives the connected/disconnected callbacks (and auto-reconnects), while the
/// stream delivers per-app flow metadata. The phone presents a self-signed cert which we
/// trust without PKI — the goal is link confidentiality; the installed CA is what
/// authenticates decrypted app traffic. All mutable state lives on a private serial
/// queue; results are delivered via callbacks the model hops to the main actor.
final class CompanionLink {
    var onDevices: (([CompanionDevice]) -> Void)?
    var onConnected: ((String, Bool) -> Void)?
    var onFlow: ((String, CompanionFlow) -> Void)?
    /// Device self-description from `Describe` on (re)connect: (id, name, build commit).
    var onDeviceInfo: ((String, String, String) -> Void)?
    /// Device capture (VPN) state heartbeat: (id, capturing). Lets the desktop show whether
    /// the VPN is actually up and notice within seconds when the user stops capture.
    var onCaptureState: ((String, Bool) -> Void)?
    /// mDNS browsing can't run — almost always macOS Local Network permission not granted.
    /// The UI surfaces this with a one-click jump to the Local Network settings.
    var onBrowseBlocked: ((Bool) -> Void)?

    /// Sentinel flow id the phone uses to carry capture state instead of a real flow.
    private static let captureStatusID = "__jaca_capture__"

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let queue = DispatchQueue(label: "dev.srsouza.jaca.companion")
    private var browser: NWBrowser?

    private final class Channel {
        let connection: ClientConnection
        var streamTask: Task<Void, Never>?
        init(_ connection: ClientConnection) { self.connection = connection }
    }
    private var channels: [String: Channel] = [:]            // guarded by queue
    private var resolved: [String: (String, UInt16)] = [:]   // id -> host:port, guarded by queue
    private var connectedIDs: Set<String> = []               // ids with a live (.ready) channel, guarded by queue

    // MARK: Discovery

    func startBrowsing() {
        queue.async {
            guard self.browser == nil else { return }
            let browser = NWBrowser(for: .bonjour(type: "_jaca._tcp", domain: nil), using: NWParameters())
            browser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.onBrowseBlocked?(false)
                case .failed, .waiting: self?.onBrowseBlocked?(true)   // usually Local Network permission
                default: break
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let devices = results.map { result -> CompanionDevice in
                    let name: String
                    if case let .service(svcName, _, _, _) = result.endpoint { name = svcName } else { name = "\(result.endpoint)" }
                    // Identity by device, not address: prefer the stable id the app advertises
                    // in its TXT record, so the same phone is a single entry across IP changes.
                    let id: String
                    if case let .bonjour(txt) = result.metadata,
                       case let .string(devID) = txt.getEntry(for: "id"), !devID.isEmpty {
                        id = devID
                    } else {
                        id = "\(result.endpoint)"
                    }
                    return CompanionDevice(id: id, name: name, endpoint: result.endpoint)
                }
                self?.onDevices?(devices.sorted { $0.name < $1.name })
            }
            browser.start(queue: self.queue)
            self.browser = browser
        }
    }

    func stopBrowsing() {
        queue.async {
            self.browser?.cancel()
            self.browser = nil
        }
    }

    // MARK: Connect

    /// Connect to an mDNS-discovered device. gRPC needs an explicit address, so the
    /// Bonjour endpoint is resolved to host:port first (cached for reconnects).
    func connect(id: String, to endpoint: NWEndpoint) {
        queue.async {
            // A live, connected channel? Leave it alone. gRPC auto-reconnects to the same
            // address on transient drops, and re-resolving on every mDNS update would churn
            // the connection (flapping between a device's IPv4/IPv6 or a stale address).
            if self.channels[id] != nil, self.connectedIDs.contains(id) { return }
            // No channel, or a dead one: resolve the current address and (re)connect. This
            // also recovers a device that came back on a new IP.
            self.resolve(endpoint) { [weak self] hp in
                self?.queue.async {
                    guard let self else { return }
                    guard let hp else { if self.channels[id] == nil { self.onConnected?(id, false) }; return }
                    if self.channels[id] != nil, self.connectedIDs.contains(id) { return } // became live meanwhile
                    if self.channels[id] != nil { self.teardown(id) }   // dead channel → replace
                    self.resolved[id] = hp
                    self.openChannel(id: id, host: hp.0, port: hp.1)
                }
            }
        }
    }

    func connect(id: String, host: String, port: UInt16) {
        queue.async {
            self.resolved[id] = (host, port)
            self.openChannel(id: id, host: host, port: port)
        }
    }

    private func openChannel(id: String, host: String, port: UInt16) {
        guard channels[id] == nil else { return } // idempotent; the channel auto-reconnects
        let delegate = ConnDelegate { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.connectedIDs.insert(id); self.onConnected?(id, true)
            case .transientFailure, .shutdown: self.connectedIDs.remove(id); self.onConnected?(id, false)
            default: break
            }
        }
        let connection = ClientConnection.usingTLS(with: Self.clientTLS(), on: group)
            .withConnectivityStateDelegate(delegate, executingOn: queue)
            .connect(host: host, port: Int(port))
        let channel = Channel(connection)
        channel.streamTask = Task { [weak self] in await self?.runStream(id: id, connection: connection) }
        channels[id] = channel
    }

    /// Keep a `StreamFlows` call running, restarting it if it ends (transient drop or the
    /// phone closing it). Connected/disconnected is owned by the connectivity delegate.
    private func runStream(id: String, connection: ClientConnection) async {
        let client = Jaca_CompanionAsyncClient(channel: connection)
        while !Task.isCancelled {
            do {
                // Identify the build on (re)connect so the desktop can flag stale apps.
                let opts = CallOptions(timeLimit: .timeout(.seconds(5)))
                if let info = try? await client.describe(Jaca_Empty(), callOptions: opts) {
                    onDeviceInfo?(id, info.name, info.version)
                }
                for try await meta in client.streamFlows(Jaca_Empty()) {
                    if meta.id == Self.captureStatusID {
                        onCaptureState?(id, meta.host == "1")   // capture-state heartbeat, not a flow
                        continue
                    }
                    onFlow?(id, CompanionFlow(
                        app: meta.app,
                        packageName: meta.packageName,
                        host: meta.host,
                        port: Int(meta.port),
                        proto: meta.`protocol`,
                    ))
                }
            } catch {
                if Task.isCancelled { break }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// Tell a connected device where the desktop's decryption proxy is.
    func setProxy(id: String, host: String, port: Int, bypass: [String]) {
        queue.async {
            guard let connection = self.channels[id]?.connection else { return }
            let client = Jaca_CompanionAsyncClient(channel: connection)
            Task {
                var cfg = Jaca_ProxyConfig()
                cfg.host = host
                cfg.port = UInt32(port)
                cfg.bypassHosts = bypass
                _ = try? await client.setProxy(cfg)
            }
        }
    }

    /// Push the desktop CA to a device so it can prompt the user to install/trust it.
    func installCa(id: String, pem: Data, name: String) {
        queue.async {
            guard let connection = self.channels[id]?.connection else { return }
            let client = Jaca_CompanionAsyncClient(channel: connection)
            Task {
                var cert = Jaca_CaCert()
                cert.pem = pem
                cert.name = name
                _ = try? await client.installCa(cert)
            }
        }
    }

    func disconnect(id: String) {
        queue.async {
            self.teardown(id)
            self.onConnected?(id, false)
        }
    }

    private func teardown(_ id: String) {
        connectedIDs.remove(id)
        if let channel = channels[id] {
            channel.streamTask?.cancel()
            _ = channel.connection.close()
        }
        channels[id] = nil
    }

    /// Trust-all TLS for the companion channel. `certificateVerification = .none` because
    /// the goal is link confidentiality, not PKI (the installed CA authenticates app
    /// traffic). ALPN must advertise h2 explicitly — without it the handshake completes but
    /// the server never sees the HTTP/2 preface and the connection is torn down.
    private static func clientTLS() -> GRPCTLSConfiguration {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .none
        tls.applicationProtocols = ["grpc-exp", "h2"]
        return .makeClientConfigurationBackedByNIOSSL(configuration: tls)
    }

    // MARK: mDNS endpoint -> host:port (gRPC needs an explicit address)

    private func resolve(_ endpoint: NWEndpoint, _ completion: @escaping ((String, UInt16)?) -> Void) {
        // Force IPv4: a Bonjour peer often resolves first to an IPv6 link-local (fe80::…%en0),
        // and link-local IPv6 is unusable once the zone is stripped — so gRPC could never dial
        // it. The phone always has a routable LAN IPv4, so prefer that.
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(to: endpoint, using: params)
        var done = false
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard !done else { return }
                done = true
                let remote = conn.currentPath?.remoteEndpoint
                conn.cancel()
                completion(remote.flatMap(Self.hostPort))
            case .failed, .cancelled:
                guard !done else { return }
                done = true
                completion(nil)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private static func hostPort(_ endpoint: NWEndpoint) -> (String, UInt16)? {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        let raw: String
        switch host {
        case .ipv4(let a): raw = "\(a)"
        case .ipv6(let a): raw = "\(a)"
        // A resolved Bonjour peer often comes back as its `.local` hostname, which gRPC/NIO
        // can't dial (it resolves via DNS, not mDNS) — so the connection silently never opens.
        // Resolve it to a concrete IPv4 ourselves (getaddrinfo uses mDNS on macOS).
        case .name(let n, _): raw = resolveToIPv4(n) ?? n
        @unknown default: return nil
        }
        let clean = raw.split(separator: "%").first.map(String.init) ?? raw // drop %en0 zone
        return (clean, port.rawValue)
    }

    /// Resolve a hostname (incl. mDNS `.local`) to its first IPv4 address, or nil. Blocking, but
    /// called on the link's private queue after the address is already in the resolver cache.
    private static func resolveToIPv4(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }
        guard let sa = info.pointee.ai_addr else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> String? in
            var addr = sin.pointee.sin_addr
            guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buf)
        }
    }
}

/// Bridges gRPC's connectivity-state delegate to a closure on our queue.
private final class ConnDelegate: ConnectivityStateDelegate {
    private let onState: (ConnectivityState) -> Void
    init(_ onState: @escaping (ConnectivityState) -> Void) { self.onState = onState }
    func connectivityStateDidChange(from oldState: ConnectivityState, to newState: ConnectivityState) {
        onState(newState)
    }
}
