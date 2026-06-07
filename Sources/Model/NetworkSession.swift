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

    /// How this session captures: in-process agent (debuggable apps) or proxy.
    private(set) var captureMode: CaptureMode = .proxy
    /// For agent mode: the debuggable app to attach to. nil → proxy (device-wide).
    var targetPackage: String?

    let ca: CertificateAuthority
    private let adbURL: URL?
    private var proxy: ProxyServer?
    private var agent: AgentController?
    private var indexByID: [UUID: Int] = [:]

    var subtitle: String {
        var parts = [device.displayModel, captureMode.label]
        if captureMode == .proxy, boundPort > 0 { parts.append(":\(boundPort)") }
        if captureMode == .agent, let p = targetPackage, !p.isEmpty { parts.append(p) }
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
        isRunning = true
        statusMessage = nil
        Task { await startBackend() }
    }

    /// Picks in-process agent (debuggable target app) when possible, else proxy.
    private func startBackend() async {
        if device.platform == .android, let adbURL, let pkg = targetPackage, !pkg.isEmpty,
           AgentArtifacts.isAvailable,
           await AgentController.isDebuggable(adbURL: adbURL, serial: device.id, package: pkg) {
            captureMode = .agent
            startAgent(adbURL: adbURL, package: pkg)
        } else {
            captureMode = .proxy
            startProxy()
        }
    }

    private func startProxy() {
        let server = ProxyServer(port: 0, ca: ca) { [weak self] txn in
            Task { @MainActor in self?.upsert(txn) }
        }
        do {
            try server.start()
            proxy = server
            boundPort = server.boundPort
            configureDeviceProxy()
            statusMessage = "proxy on \(hostAddress):\(boundPort) — install the CA & trust it"
        } catch {
            isRunning = false
            statusMessage = "Failed to start proxy: \(error.localizedDescription)"
        }
    }

    private func startAgent(adbURL: URL, package: String) {
        guard let so = AgentArtifacts.soURL(), let boot = AgentArtifacts.bootDexURL,
              let cap = AgentArtifacts.captureDexURL else {
            captureMode = .proxy; startProxy(); return
        }
        let controller = AgentController(
            adbURL: adbURL, serial: device.id, package: package,
            soPath: so, bootDexPath: boot, captureDexPath: cap,
            onTransaction: { [weak self] txn in Task { @MainActor in self?.upsert(txn) } },
            onStatus: { [weak self] s in Task { @MainActor in self?.statusMessage = s } }
        )
        agent = controller
        controller.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if captureMode == .proxy {
            unconfigureDeviceProxy()
            proxy?.stop(); proxy = nil
        } else {
            agent?.stop(); agent = nil
        }
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
        // Don't mutate a real device's proxy during UI tests.
        if ProcessInfo.processInfo.environment["SQUEEZE_UITEST"] == "1" { return }
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
