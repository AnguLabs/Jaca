import Foundation

/// Companion capture. Two streams from the Jaca mobile agent:
///  1. flow metadata (app + host:port) over the companion connection — shown immediately,
///     attributed per app, even before the CA is trusted;
///  2. decrypted request/response — the desktop runs a MITM proxy (reusing ProxyServer
///     + the Keychain CA) and tells the phone to tunnel its TLS connections here, so the
///     CA private key never leaves this Mac.
@MainActor
final class CompanionCaptureSource: CaptureSource {
    private let device: Device
    private let hub: CompanionHub
    private let ca: CertificateAuthority
    private var proxy: ProxyServer?

    init(device: Device, hub: CompanionHub, ca: CertificateAuthority) {
        self.device = device
        self.hub = hub
        self.ca = ca
    }

    private var companionID: String { device.companionID ?? device.id }

    func start(into sink: CaptureSink) {
        // Never surface the companion's own traffic to the desktop (defence-in-depth:
        // the phone already excludes Jaca from the VPN, so these never get captured).
        let selfIP = LANAddress.current()

        // 1. Metadata stream.
        hub.subscribe(id: companionID) { [weak sink] flow in
            if flow.host == selfIP { return }
            sink?.capture(didReceive: Self.transaction(from: flow))
        }
        hub.connect(id: companionID)

        // 2. Decryption proxy: spin up a MITM and tell the phone to tunnel through it.
        let server = ProxyServer(port: 0, ca: ca) { [weak sink] txn in
            if txn.host == selfIP { return }
            Task { @MainActor in sink?.capture(didReceive: txn) }
        }
        if (try? server.start()) != nil {
            proxy = server
            if let host = LANAddress.current() {
                hub.send(id: companionID, line: #"{"type":"proxy","host":"\#(host)","port":\#(server.boundPort)}"#)
            }
        }
        sink.capture(didChangeStatus: "Streaming from \(device.displayModel)")
    }

    func stop() {
        hub.unsubscribe(id: companionID)
        hub.disconnect(id: companionID)
        proxy?.stop()
        proxy = nil
    }

    /// Synthesize a transaction from a companion flow (pre-decryption visibility). The
    /// owning app/package is carried in a header so the package filter can use it.
    static func transaction(from flow: CompanionFlow) -> NetworkTransaction {
        let appHeader = HeaderPair(name: "X-Jaca-App", value: "\(flow.app) (\(flow.packageName))")
        var txn = NetworkTransaction(
            method: flow.proto,
            url: "\(flow.host):\(flow.port)",
            host: flow.host,
            scheme: flow.proto.lowercased(),
            requestHeaders: [appHeader],
        )
        txn.responseHeaders = [appHeader]
        txn.finishedAt = txn.startedAt
        return txn
    }
}
