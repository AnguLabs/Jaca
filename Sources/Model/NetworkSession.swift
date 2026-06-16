import Foundation
import Observation

/// One network-inspection tab. The user explicitly picks a capture mode — proxy
/// (device-wide MITM) or in-process agent (one debuggable Android app) — and only
/// then does capture start. Proxy mode configures the Android device's HTTP proxy
/// while running and reverts it on stop; iOS surfaces manual setup (see
/// NetworkSetupSheet).
@MainActor
@Observable
final class NetworkSession: WorkspaceTab {
    let id = UUID()
    var displayName: String { didSet { onStateChanged?() } }
    let device: Device

    /// Called when persisted state (target app / name) changes, so the open-tabs
    /// snapshot is saved immediately rather than only on quit.
    var onStateChanged: (() -> Void)?

    private(set) var isRunning = false
    private(set) var isConnecting = false
    private(set) var transactions: [NetworkTransaction] = []
    var selectedID: UUID? {
        didSet { if let id = selectedID, id != oldValue { ensureBodies(for: id) } }
    }
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
    /// Whether the user has explicitly chosen a capture mode. Capture never starts
    /// (and the device proxy is never configured) until this is true — a fresh tab
    /// shows the mode chooser instead of silently turning on the proxy.
    private(set) var hasSelectedMode = false

    /// In-process agent capture: Android (bundled .so/.dex) or iOS Simulator (injected
    /// JacaNetAgent dylib). No proxy/CA for either.
    var agentAvailable: Bool {
        (device.platform == .android && AgentArtifacts.isAvailable)
            || (device.platform == .iosSimulator && AgentArtifacts.iosNetworkAgentAvailable)
    }

    let ca: CertificateAuthority
    private let adbURL: URL?
    private var proxy: ProxyServer?
    private var agent: AgentController?
    private var iosAgent: IOSSimulatorAgentController?
    private var indexByID: [UUID: Int] = [:]
    private let bodyCache: NetworkBodyCache?
    /// Full request/response bodies stay in memory for the most recent N transactions;
    /// older ones spill to the on-disk cache (metadata stays, so the list and timeline
    /// still render) and load back on demand when opened.
    private let bodiesInMemory = 1_000

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

    init(device: Device, ca: CertificateAuthority, adbURL: URL?, displayName: String? = nil,
         bodyCache: NetworkBodyCache? = nil) {
        self.device = device
        self.ca = ca
        self.adbURL = adbURL
        self.displayName = displayName ?? "Network · \(device.displayModel)"
        self.bodyCache = bodyCache
    }

    /// Explicitly begin device-wide MITM proxy capture. On Android this configures
    /// the device's global HTTP proxy while running, so it's strictly user-initiated.
    func startProxyCapture() {
        targetPackage = nil
        captureMode = .proxy
        hasSelectedMode = true
        onStateChanged?()
        beginConnecting()
    }

    /// Explicitly begin in-process agent capture for one debuggable app (no proxy/CA).
    func startAgentCapture(package: String) {
        targetPackage = package
        captureMode = .agent
        hasSelectedMode = true
        onStateChanged?()
        beginConnecting()
    }

    /// Restart whichever mode was last chosen — the toolbar play button after a stop.
    func resume() {
        guard hasSelectedMode else { return }
        if captureMode == .agent, let pkg = targetPackage, !pkg.isEmpty {
            startAgentCapture(package: pkg)
        } else {
            startProxyCapture()
        }
    }

    /// Brings the chosen mode up. Proxy mode runs a local MITM server and can
    /// capture regardless of device reachability (point a device/sim at it
    /// manually; on a reachable Android device the proxy is auto-configured as a
    /// best effort). Agent mode must reach the device to attach in-process, so it
    /// verifies the device is up and the target app is installed first.
    private func beginConnecting() {
        guard !isRunning, !isConnecting else { return }
        statusMessage = nil
        if captureMode == .proxy {
            start()
            return
        }
        isConnecting = true
        Task { @MainActor in
            let available = await checkDeviceAvailable()
            guard available else {
                isConnecting = false
                statusMessage = deviceUnavailableMessage
                return
            }
            // The app must exist. We DON'T block on "not running" — the agent
            // supervisor waits for the app and re-attaches on each restart.
            if device.platform == .android, let pkg = targetPackage, !pkg.isEmpty,
               await !isPackageInstalled(pkg) {
                isConnecting = false
                statusMessage = "App “\(pkg)” isn’t installed on \(device.displayModel)."
                return
            }
            isConnecting = false
            start()
        }
    }

    func start() {
        // Never capture (and never touch the device proxy) without an explicit choice.
        guard !isRunning, hasSelectedMode else { return }
        isRunning = true
        statusMessage = nil
        Task { await startBackend() }
    }

    /// Runs the backend for the mode the user chose. Agent mode surfaces a clear
    /// error rather than silently falling back to the proxy.
    private func startBackend() async {
        switch captureMode {
        case .proxy:
            startProxy()
        case .agent:
            guard let pkg = targetPackage, !pkg.isEmpty else {
                isRunning = false
                statusMessage = "Pick an app to inspect."
                return
            }
            switch device.platform {
            case .android:
                guard let adbURL, AgentArtifacts.isAvailable else {
                    isRunning = false
                    statusMessage = "The in-process agent isn’t available for this app."
                    return
                }
                startAgent(adbURL: adbURL, package: pkg)
            case .iosSimulator:
                guard let dylib = AgentArtifacts.iosNetworkAgentURL else {
                    isRunning = false
                    statusMessage = "The in-process network agent isn’t bundled."
                    return
                }
                startIOSAgent(dylib: dylib, bundleID: pkg)
            case .iosDevice:
                isRunning = false
                statusMessage = "In-process capture isn’t supported on physical devices yet."
            }
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

    private func startIOSAgent(dylib: URL, bundleID: String) {
        let controller = IOSSimulatorAgentController(
            udid: device.id, bundleID: bundleID, agentDylib: dylib,
            onTransaction: { [weak self] txn in Task { @MainActor in self?.upsert(txn) } },
            onStatus: { [weak self] s in Task { @MainActor in self?.statusMessage = s } }
        )
        iosAgent = controller
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
            iosAgent?.stop(); iosAgent = nil
        }
    }

    func toggle() { isRunning ? stop() : resume() }

    private func isPackageInstalled(_ package: String) async -> Bool {
        guard let adbURL else { return false }
        let r = try? await CommandRunner.run(adbURL, ["-s", device.id, "shell", "pm", "list", "packages", package])
        return r?.stdout.contains("package:\(package)") ?? false
    }

    private var deviceUnavailableMessage: String {
        switch device.platform {
        case .android:
            return "\(device.displayModel) isn’t connected — plug it in and authorize USB debugging."
        case .iosSimulator:
            return "\(device.displayModel) isn’t booted — start the simulator and try again."
        case .iosDevice:
            return "\(device.displayModel) isn’t connected — plug it in and trust this Mac."
        }
    }

    private func checkDeviceAvailable() async -> Bool {
        switch device.platform {
        case .android:
            guard let adbURL else { return false }
            let r = try? await CommandRunner.run(adbURL, ["-s", device.id, "get-state"])
            return r?.exitCode == 0 && (r?.stdout.contains("device") ?? false)
        case .iosSimulator:
            let r = try? await CommandRunner.run(AppleToolchain.xcrun, ["simctl", "list", "devices", "booted"])
            return r?.stdout.contains(device.id) ?? false
        case .iosDevice:
            let r = try? await CommandRunner.run(AppleToolchain.xcrun, ["devicectl", "list", "devices"])
            return r?.stdout.contains(device.id) ?? false
        }
    }

    var isAndroid: Bool { device.platform == .android }

    /// Apps installed on the device (for the in-process-agent target picker).
    func installedApps() async -> [AppEntry] {
        await InstalledApps.list(for: device, adbURL: adbURL)
    }

    /// Whether `package` can be captured in-process. Android: must be debuggable
    /// (run-as). iOS Simulator: any installed app accepts DYLD_INSERT_LIBRARIES.
    func isDebuggable(_ package: String) async -> Bool {
        switch device.platform {
        case .iosSimulator:
            return true
        case .android:
            guard let adbURL else { return false }
            return await AgentController.isDebuggable(adbURL: adbURL, serial: device.id, package: package)
        case .iosDevice:
            return false
        }
    }

    /// Choose what to capture: a specific app (in-process agent) or the whole
    /// device (proxy). Either choice is an explicit start of that mode — picking
    /// an app starts the agent; picking "whole device" starts the proxy.
    func setTarget(_ package: String?) {
        if isRunning { stop() }
        if let pkg = package, !pkg.isEmpty {
            startAgentCapture(package: pkg)
        } else {
            startProxyCapture()
        }
    }

    func clear() {
        transactions.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        selectedID = nil
        selectedTimeRange = nil   // reset the timeline window too
    }

    func upsert(_ txn: NetworkTransaction) {   // internal: capture pipeline + tests
        if let idx = indexByID[txn.id] {
            transactions[idx] = txn
        } else {
            indexByID[txn.id] = transactions.count
            transactions.append(txn)
            // Nothing is dropped — spill the body of whichever transaction just fell
            // out of the in-memory window to disk (its metadata stays for the list).
            if transactions.count > bodiesInMemory {
                evictBodies(at: transactions.count - bodiesInMemory - 1)
            }
        }
    }

    /// Persists an older transaction's bodies to the disk cache, then clears them from
    /// memory (the list/timeline only need metadata; the detail view reloads on open).
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

    /// Loads an evicted transaction's bodies back from disk (when it's selected). The
    /// detail view re-renders once they arrive.
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

    // MARK: - Device proxy

    private func configureDeviceProxy() {
        // Don't mutate a real device's proxy during UI tests.
        if ProcessInfo.processInfo.environment["JACA_UITEST"] == "1" { return }
        guard device.platform == .android, let adbURL else { return }
        let serial = device.id, host = hostAddress, port = boundPort
        // Arm the global cleanup registry first, so a crash/kill between setting the
        // proxy and a normal stop() still gets reverted on the way out.
        ProxyCleanup.register(adbPath: adbURL.path, serial: serial)
        Task {
            await ProxyConfigurator.setAndroidProxy(adbURL: adbURL, serial: serial, host: host, port: port)
            await MainActor.run { self.proxyConfigured = true }
        }
    }

    private func unconfigureDeviceProxy() {
        guard device.platform == .android, let adbURL, proxyConfigured else { return }
        let serial = device.id
        proxyConfigured = false
        ProxyCleanup.deregister(adbPath: adbURL.path, serial: serial)
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
                    ? "CA pushed to /sdcard/Download/JacaProxyCA.pem — install it in Settings."
                    : "Failed to push CA certificate."
            }
        }
    }
}
