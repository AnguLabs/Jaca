import Foundation
import Observation

/// One network-inspection tab: runs a MITM proxy bound to a device and collects
/// captured HTTP(S) transactions. Auto-configures the Android device proxy; for
/// iOS it surfaces manual setup (see NetworkSetupSheet).
@MainActor
@Observable
final class NetworkSession: WorkspaceTab {
    let id = UUID()
    var displayName: String
    let device: Device

    private(set) var isRunning = false
    private(set) var transactions: [NetworkTransaction] = []
    var selectedID: UUID?
    var filterText = ""
    /// Time window selected on the timeline; nil = all time.
    var selectedTimeRange: ClosedRange<Date>?
    var statusMessage: String?
    private(set) var boundPort: Int = 0
    private(set) var proxyConfigured = false

    let ca: CertificateAuthority
    private let adbURL: URL?
    private var proxy: ProxyServer?
    private var indexByID: [UUID: Int] = [:]

    var subtitle: String {
        var parts = [device.displayModel]
        if boundPort > 0 { parts.append(":\(boundPort)") }
        if !isRunning { parts.append("stopped") }
        return parts.joined(separator: " · ")
    }

    var hostAddress: String { ProxyConfigurator.hostAddress(for: device) }

    var filtered: [NetworkTransaction] {
        let q = filterText
        return transactions.filter { txn in
            if let range = selectedTimeRange {
                let end = txn.finishedAt ?? txn.startedAt
                // keep if the transaction's [start, end] overlaps the selection
                if txn.startedAt > range.upperBound || end < range.lowerBound { return false }
            }
            if q.isEmpty { return true }
            return txn.url.range(of: q, options: .caseInsensitive) != nil
                || txn.host.range(of: q, options: .caseInsensitive) != nil
                || txn.method.range(of: q, options: .caseInsensitive) != nil
        }
    }

    var selected: NetworkTransaction? {
        guard let selectedID, let idx = indexByID[selectedID] else { return nil }
        return transactions[idx]
    }

    init(device: Device, ca: CertificateAuthority, adbURL: URL?, displayName: String? = nil) {
        self.device = device
        self.ca = ca
        self.adbURL = adbURL
        self.displayName = displayName ?? "Network · \(device.displayModel)"
    }

    func start() {
        guard !isRunning else { return }
        let server = ProxyServer(port: 0, ca: ca) { [weak self] txn in
            Task { @MainActor in self?.upsert(txn) }
        }
        do {
            try server.start()
            proxy = server
            boundPort = server.boundPort
            isRunning = true
            statusMessage = nil
            configureDeviceProxy()
        } catch {
            statusMessage = "Failed to start proxy: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        unconfigureDeviceProxy()
        proxy?.stop()
        proxy = nil
    }

    func toggle() { isRunning ? stop() : start() }

    func clear() {
        transactions.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        selectedID = nil
    }

    private func upsert(_ txn: NetworkTransaction) {
        if let idx = indexByID[txn.id] {
            transactions[idx] = txn
        } else {
            indexByID[txn.id] = transactions.count
            transactions.append(txn)
        }
    }

    // MARK: - Device proxy

    private func configureDeviceProxy() {
        guard device.platform == .android, let adbURL else { return }
        let serial = device.id, host = hostAddress, port = boundPort
        Task {
            await ProxyConfigurator.setAndroidProxy(adbURL: adbURL, serial: serial, host: host, port: port)
            await MainActor.run { self.proxyConfigured = true }
        }
    }

    private func unconfigureDeviceProxy() {
        guard device.platform == .android, let adbURL, proxyConfigured else { return }
        let serial = device.id
        proxyConfigured = false
        Task { await ProxyConfigurator.clearAndroidProxy(adbURL: adbURL, serial: serial) }
    }

    func pushCAToDevice() {
        guard device.platform == .android, let adbURL else { return }
        let serial = device.id
        let caURL = ca.storageDirectory.appendingPathComponent("rootCA.pem")
        Task {
            let ok = await ProxyConfigurator.pushCACertToAndroid(adbURL: adbURL, serial: serial, caPEM: caURL)
            await MainActor.run {
                statusMessage = ok
                    ? "CA pushed to /sdcard/Download/SqueezeProxyCA.pem — install it in Settings."
                    : "Failed to push CA certificate."
            }
        }
    }
}
