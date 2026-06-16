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
    /// Set once a MITM handshake succeeds — CA is trusted and decryption works.
    private var decryptionConfirmed = false
    /// Set once we've pushed the CA to the device (auto mode), so we don't nag repeatedly.
    private var caInstallRequested = false
    /// Hosts a client rejected (pins / distrusts the CA) — bypassed so that app keeps working.
    private var bypassHosts: Set<String> = []
    /// Periodically re-advertises the proxy: the phone may connect, start capturing, or
    /// reconnect on a new channel after our first advertise — re-sending (idempotent on the
    /// phone) guarantees the decryption tunnel engages regardless of ordering.
    private var reapplyTask: Task<Void, Never>?

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

        // 2. Decryption proxy: spin up a MITM and tell the phone to tunnel through it. The
        //    handshake outcome auto-validates the CA: success = the device trusts our leaf
        //    (decryption works); failure = CA not installed.
        let label = device.displayModel
        let server = ProxyServer(port: 0, ca: ca, onTransaction: { [weak sink] txn in
            if txn.host == selfIP { return }
            Task { @MainActor in sink?.capture(didReceive: txn) }
        }, onHandshake: { [weak self, weak sink] host, ok in
            Task { @MainActor in
                guard let self else { return }
                if ok {
                    self.decryptionConfirmed = true
                    sink?.capture(didChangeStatus: "Decrypting \(label) ✓")
                } else {
                    // This host's client rejected our cert (it pins or doesn't trust the CA).
                    // Bypass it so that app keeps working; keep decrypting the cooperating ones.
                    if self.bypassHosts.insert(host).inserted {
                        self.applyProxy()
                        sink?.capture(didChangeStatus: "Passing \(host) through — it rejects the certificate")
                    }
                    // Until anything decrypts, the likely cause is the CA not being installed.
                    if !self.decryptionConfirmed, !self.caInstallRequested {
                        self.caInstallRequested = true
                        self.hub.installCa(id: self.companionID, pem: Data(self.ca.rootCertificatePEM.utf8))
                    }
                }
            }
        })
        if (try? server.start()) != nil {
            proxy = server
            applyProxy()
            // Keep re-advertising until decryption is confirmed: the phone might not be capturing
            // yet (so its proxy handler isn't wired), or it may reconnect on a new channel.
            reapplyTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, !self.decryptionConfirmed else { continue }
                    self.applyProxy()
                }
            }
        }
        sink.capture(didChangeStatus: "Streaming from \(device.displayModel)")
    }

    /// (Re)advertise the proxy address and the current bypass list to the device.
    private func applyProxy() {
        guard let proxy, let host = LANAddress.current() else { return }
        hub.setProxy(id: companionID, host: host, port: proxy.boundPort, bypass: Array(bypassHosts))
    }

    func stop() {
        reapplyTask?.cancel()
        reapplyTask = nil
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
