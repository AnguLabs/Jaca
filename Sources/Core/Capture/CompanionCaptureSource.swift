import Foundation

/// Companion capture: receives per-app flow metadata streamed from the Jaca mobile agent
/// over the LAN (no proxy, no ADB) and surfaces each as a transaction, attributed to its
/// app. Desktop-side decryption lands later; this already shows who-talks-to-whom per app.
@MainActor
final class CompanionCaptureSource: CaptureSource {
    private let device: Device
    private let hub: CompanionHub

    init(device: Device, hub: CompanionHub) {
        self.device = device
        self.hub = hub
    }

    private var companionID: String { device.companionID ?? device.id }

    func start(into sink: CaptureSink) {
        hub.subscribe(id: companionID) { [weak sink] flow in
            sink?.capture(didReceive: Self.transaction(from: flow))
        }
        hub.connect(id: companionID)
        sink.capture(didChangeStatus: "Streaming from \(device.displayModel)")
    }

    func stop() {
        hub.unsubscribe(id: companionID)
        hub.disconnect(id: companionID)
    }

    /// Synthesize a transaction from a companion flow. The owning app/package is carried
    /// in a header so the package filter (and a future decrypt layer) can use it.
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
