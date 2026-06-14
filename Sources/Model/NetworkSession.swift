import Foundation
import Observation

/// One network-inspection tab. The user picks a capture source — proxy (device-wide
/// MITM), in-process agent (one debuggable Android app), companion (stream from the Jaca
/// mobile agent), or any future one — from `CaptureSourceRegistry`, and only then does
/// capture start. The session itself is generic: it runs whichever `CaptureSource` was
/// chosen and reacts to its events via `CaptureSink`, so adding a source touches nothing
/// here.
@MainActor
@Observable
final class NetworkSession: WorkspaceTab, CaptureSink {
    let id = UUID()
    var displayName: String { didSet { onStateChanged?() } }
    let device: Device

    var onStateChanged: (() -> Void)?
    var deviceContext: DeviceContext?

    private(set) var isRunning = false
    private(set) var isConnecting = false
    private(set) var transactions: [NetworkTransaction] = []
    var selectedID: UUID? {
        didSet { if let id = selectedID, id != oldValue { ensureBodies(for: id) } }
    }
    var filterText = ""
    var selectedTimeRange: ClosedRange<Date>?
    var statusMessage: String?
    private(set) var boundPort: Int = 0

    /// The live CA-install flow shown in `CAInstallSheet` (proxy mode).
    private(set) var caInstaller: AndroidCACertInstaller?
    /// Ground truth that the CA is trusted: flips true once a real HTTPS request is decrypted.
    private(set) var caReady = false
    /// Proxy started but the CA isn't confirmed — the view surfaces the setup dialog.
    var proxyNeedsSetup = false

    /// The chosen capture source (registry id), and whether the user has chosen one.
    private(set) var selectedSourceID: String?
    private(set) var hasSelectedMode = false
    /// Agent mode: the debuggable app to attach to. nil otherwise.
    var targetPackage: String?

    let ca: CertificateAuthority
    private let adbURL: URL?
    private let companion: CompanionHub?
    private var current: CaptureSource?
    private var indexByID: [UUID: Int] = [:]
    private let bodyCache: NetworkBodyCache?
    private let bodiesInMemory = 1_000

    /// Capture options offered for this device (from the registry), in display order.
    var availableSources: [CaptureSourceDescriptor] {
        CaptureSourceRegistry.options(for: device, context: deviceContext)
    }
    /// The chosen source's descriptor (drives badge, subtitle, empty-state text).
    var currentDescriptor: CaptureSourceDescriptor? {
        selectedSourceID.flatMap { CaptureSourceRegistry.descriptor(id: $0) }
    }
    /// The chosen source kind, defaulting to proxy before a choice is made.
    var captureMode: CaptureMode { currentDescriptor?.kind ?? .proxy }

    /// True while the proxy source has the device's HTTP proxy configured (stranded-proxy
    /// detection + status bar). Read-only view of the running source's state.
    var proxyConfigured: Bool { (current as? ProxyCaptureSource)?.isProxyConfigured ?? false }

    /// In-process agent capture is Android-only and needs the bundled agent artifacts.
    var agentAvailable: Bool { device.platform == .android && AgentArtifacts.isAvailable }
    var isAndroid: Bool { device.platform == .android }

    var subtitle: String {
        var parts = [device.displayModel]
        if let d = currentDescriptor { parts.append(d.label) }
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
                if txn.startedAt > range.upperBound || end < range.lowerBound { return false }
            }
            if q.isEmpty { return true }
            return txn.url.range(of: q, options: .caseInsensitive) != nil
                || txn.host.range(of: q, options: .caseInsensitive) != nil
                || txn.method.range(of: q, options: .caseInsensitive) != nil
                // Companion rows carry the owning app here, so the filter doubles as a package filter.
                || txn.responseHeaders.contains { $0.name == "X-Jaca-App" && $0.value.range(of: q, options: .caseInsensitive) != nil }
        }
    }

    var selected: NetworkTransaction? {
        guard let selectedID, let idx = indexByID[selectedID] else { return nil }
        return transactions[idx]
    }

    init(device: Device, ca: CertificateAuthority, adbURL: URL?, displayName: String? = nil,
         bodyCache: NetworkBodyCache? = nil, companion: CompanionHub? = nil) {
        self.device = device
        self.ca = ca
        self.adbURL = adbURL
        self.displayName = displayName ?? "Network · \(device.displayModel)"
        self.bodyCache = bodyCache
        self.companion = companion
    }

    // MARK: - Source selection (generic)

    /// Choose a capture source and start it. The single entry point for every source.
    func select(_ descriptor: CaptureSourceDescriptor, package: String? = nil) {
        if isRunning { stop() }
        targetPackage = descriptor.needsPackage ? package : nil
        selectedSourceID = descriptor.id
        hasSelectedMode = true
        onStateChanged?()
        start()
    }

    /// Restores the chosen source from persistence WITHOUT starting — a relaunched tab
    /// comes back pre-configured so the user just presses play.
    func restoreMode(_ mode: CaptureMode, package: String?) {
        selectedSourceID = CaptureSourceRegistry.all.first { $0.kind == mode }?.id
        targetPackage = (mode == .agent) ? package : nil
        hasSelectedMode = true
    }

    /// Returns the tab to the chooser — the "switch source" escape hatch.
    func reopenModeChooser() {
        if isRunning { stop() }
        hasSelectedMode = false
        proxyNeedsSetup = false
    }

    /// Restart the chosen source — the toolbar play button after a stop.
    func resume() {
        guard hasSelectedMode, let descriptor = currentDescriptor else { return }
        select(descriptor, package: targetPackage)
    }

    func start() {
        guard !isRunning, !isConnecting, hasSelectedMode, let descriptor = currentDescriptor else { return }
        statusMessage = nil
        guard let precheck = descriptor.precheck else { launch(descriptor); return }
        // A source that needs the device reachable (agent) verifies first and surfaces a
        // clear message instead of silently failing.
        isConnecting = true
        Task { @MainActor in
            let error = await precheck(makeContext())
            isConnecting = false
            if let error { statusMessage = error; return }
            launch(descriptor)
        }
    }

    private func launch(_ descriptor: CaptureSourceDescriptor) {
        guard !isRunning else { return }
        isRunning = true
        let source = descriptor.make(makeContext())
        current = source
        source.start(into: self)
    }

    private func makeContext() -> CaptureContext {
        CaptureContext(device: device, adbURL: adbURL, ca: ca, deviceContext: deviceContext,
                       targetPackage: targetPackage, companion: companion)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        proxyNeedsSetup = false
        current?.stop()
        current = nil
    }

    func toggle() { isRunning ? stop() : resume() }

    // MARK: - Convenience wrappers (used by the chooser + app picker)

    func startProxyCapture() {
        guard let d = CaptureSourceRegistry.descriptor(id: "proxy") else { return }
        select(d)
    }

    func startAgentCapture(package: String) {
        guard let d = CaptureSourceRegistry.descriptor(id: "agent") else { return }
        select(d, package: package)
    }

    func startCompanionCapture() {
        guard let d = CaptureSourceRegistry.descriptor(id: "companion") else { return }
        select(d)
    }

    /// Choose what to capture: a specific app (agent) or the whole device (proxy).
    func setTarget(_ package: String?) {
        if let pkg = package, !pkg.isEmpty { startAgentCapture(package: pkg) } else { startProxyCapture() }
    }

    // MARK: - CaptureSink (events from the running source)

    func capture(didReceive transaction: NetworkTransaction) { upsert(transaction) }
    func capture(didChangeStatus status: String?) { statusMessage = status }
    func capture(didBindPort port: Int) { boundPort = port }
    func captureNeedsSetup() {
        if !caReady { proxyNeedsSetup = true }
    }

    // MARK: - Apps (agent target picker)

    func installedApps() async -> [AppEntry] { await InstalledApps.list(for: device, adbURL: adbURL) }

    func isDebuggable(_ package: String) async -> Bool {
        guard let adbURL, device.platform == .android else { return false }
        return await AgentController.isDebuggable(adbURL: adbURL, serial: device.id, package: package)
    }

    func clear() {
        transactions.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        selectedID = nil
        selectedTimeRange = nil
    }

    func upsert(_ txn: NetworkTransaction) {
        // First successfully MITM'd HTTPS request confirms the CA is trusted.
        if txn.scheme == "https", txn.error == nil {
            caReady = true
            proxyNeedsSetup = false
            caInstaller?.noteInterceptionConfirmed()
        }
        if let idx = indexByID[txn.id] {
            transactions[idx] = txn
        } else {
            indexByID[txn.id] = transactions.count
            transactions.append(txn)
            if transactions.count > bodiesInMemory {
                evictBodies(at: transactions.count - bodiesInMemory - 1)
            }
        }
    }

    private func evictBodies(at index: Int) {
        guard let cache = bodyCache,
              index >= 0, index < transactions.count, !transactions[index].bodiesEvicted else { return }
        let txn = transactions[index]
        guard txn.requestBody != nil || txn.responseBody != nil else {
            transactions[index].bodiesEvicted = true; return
        }
        let id = txn.id, req = txn.requestBody, resp = txn.responseBody
        Task {
            await cache.save(id, req: req, resp: resp)
            await MainActor.run { [weak self] in self?.stripBodies(id) }
        }
    }

    private func stripBodies(_ id: UUID) {
        guard let idx = indexByID[id] else { return }
        transactions[idx].requestBody = nil
        transactions[idx].responseBody = nil
        transactions[idx].bodiesEvicted = true
    }

    func ensureBodies(for id: UUID) {
        guard let idx = indexByID[id], transactions[idx].bodiesEvicted,
              transactions[idx].requestBody == nil, transactions[idx].responseBody == nil,
              let cache = bodyCache else { return }
        Task {
            let bodies = await cache.load(id)
            await MainActor.run { [weak self] in
                guard let self, let i = self.indexByID[id] else { return }
                self.transactions[i].requestBody = bodies.req
                self.transactions[i].responseBody = bodies.resp
                self.transactions[i].bodiesEvicted = false
            }
        }
    }

    // MARK: - CA (proxy mode)

    func pushCAToDevice() {
        guard device.platform == .android, let adbURL else { return }
        let serial = device.id
        let caURL = ca.storageDirectory.appendingPathComponent("rootCA.pem")
        Task {
            let ok = await ProxyConfigurator.pushCACertToAndroid(adbURL: adbURL, serial: serial, caPEM: caURL)
            await MainActor.run {
                statusMessage = ok
                    ? "CA pushed to /sdcard/Download/JacaProxyCA.pem — install it in Settings."
                    : "Failed to push CA certificate."
            }
        }
    }

    func prepareCAInstall() async {
        guard device.platform == .android, let adbURL else { return }
        let caURL = ca.storageDirectory.appendingPathComponent("rootCA.pem")
        let caps: AndroidCapabilities
        if let cached = deviceContext?.capabilities { caps = cached }
        else { caps = await AndroidCapabilityProbe.probe(adbURL: adbURL, serial: device.id) }
        caInstaller = AndroidCACertInstaller(adbURL: adbURL, serial: device.id, caPEM: caURL, capabilities: caps)
    }

    func cancelCAInstall() {
        caInstaller?.cancel()
        if isRunning { stop() }
    }
}
