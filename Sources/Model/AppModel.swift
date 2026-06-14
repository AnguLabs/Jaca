import Foundation
import Observation

/// The top-level areas of the app.
enum WorkspaceMode: String { case devices, projects, gradle, xcode }

/// Root app state: the merged live device list and the ordered set of log
/// sessions (tabs). Providers are pluggable, so iOS slots in by appending another
/// `DeviceProvider` and a matching `LogSource` in `startSession`.
@MainActor
@Observable
final class AppModel {
    private(set) var devices: [Device] = []
    private(set) var sessions: [any WorkspaceTab] = []
    var selectedSessionID: UUID?

    /// Top-level area the app is showing: the device/session view or the worktrees area.
    var mode: WorkspaceMode = .devices

    /// The unified Projects area state: auto-detected Claude projects + user-added
    /// folders, their worktrees, and per-checkout cache cleanup.
    let projects = ProjectsModel()

    /// The Gradle daemons area state (lists/kills running Gradle daemons).
    let gradle = GradleDaemonsModel()

    /// The Xcode DerivedData area state (lists/deletes build caches; flags stale ones).
    let xcode = DerivedDataModel()

    /// Resolved adb path; nil means the toolchain wasn't found (surface in UI).
    private(set) var adbURL: URL?

    /// Persistent log history (nil only if the DB couldn't be opened).
    let history: HistoryStore?

    /// History retention; sessions older than this are pruned on launch.
    var retention: TimeInterval = 7 * 24 * 60 * 60

    var selectedSession: (any WorkspaceTab)? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    private var providers: [DeviceProvider] = []
    private var discoveryTasks: [Task<Void, Never>] = []
    private var devicesByPlatform: [DevicePlatform: [Device]] = [:]

    /// Companion discovery: Jaca mobile agents found over mDNS, and which are streaming.
    /// Shared by every companion network session. Surfaced in the device list as a chip
    /// (on an adb device) or its own entry (companion-only).
    let companionHub = CompanionHub()
    private var companionDevices: [CompanionDevice] = []
    private var companionConnectedIDs: Set<String> = []
    /// Companion ids we've already sent the CA to on this connection (re-sent on reconnect).
    private var companionCAPushed: Set<String> = []
    /// Build commit each connected companion reported (id -> hash), for update detection.
    private var companionVersions: [String: String] = [:]
    private let companionStore = CompanionDeviceStore()
    /// Companion devices seen before (persisted), shown offline until rediscovered.
    private var knownCompanions: [CompanionDeviceStore.Cached] = []
    /// QR / web / adb onboarding for connecting a new device (set in init).
    private(set) var companionSetup: CompanionSetupModel!

    /// Per-device shared state (capabilities + installed-app polling), one per
    /// `Device.id`, reused by every tab for that device. Created with the first
    /// tab and torn down when the last tab for a device closes.
    private var deviceContexts: [String: DeviceContext] = [:]

    /// Tabs persisted from a previous launch, restored as their devices appear.
    private var pendingRestores: [TabDescriptor] = []
    private var isRestoring = false
    private static let tabsKey = "openTabs"
    /// Clean, isolated state for UI tests (no restore, no persistence pollution).
    private let uiTestMode = ProcessInfo.processInfo.environment["JACA_UITEST"] == "1"
    /// UI-test hook: auto-open a session for the first ready device of this
    /// platform (works around macOS not delivering content clicks to an inactive
    /// test window). Value is a DevicePlatform rawValue.
    private let autoSessionPlatform = ProcessInfo.processInfo.environment["JACA_AUTO_SESSION"]
        .flatMap { DevicePlatform(rawValue: $0) }

    init() {
        history = HistoryStore()
        if let days = UserDefaults.standard.object(forKey: "retentionDays") as? Int, days > 0 {
            retention = TimeInterval(days) * 86_400
        }
        if !uiTestMode { pendingRestores = Self.loadPersistedTabs(); knownCompanions = companionStore.load() }
        buildProviders()
        companionSetup = CompanionSetupModel(hub: companionHub, adbURL: adbURL,
                                             caCertPEM: { [weak self] in self?.ensureCA()?.rootCertificatePEM })
        // Push global message-exclusion edits to every open log tab, live.
        LogExclusionStore.shared.onChange = { [weak self] in
            guard let self else { return }
            let rules = LogExclusionStore.shared.rules
            for case let session as LogSession in self.sessions { session.applyExclusions(rules) }
        }
        let store = history
        let cutoff = Date().addingTimeInterval(-retention)
        Task { await store?.prune(olderThan: cutoff) }
    }

    private func buildProviders() {
        adbURL = AndroidToolchain.adbURL(override: UserDefaults.standard.string(forKey: "adbPath"))
        providers = []
        if let adbURL {
            providers.append(AndroidDeviceProvider(adbURL: adbURL))
        }
        providers.append(SimulatorDeviceProvider())   // self-guards when no Xcode
        providers.append(IOSDeviceProvider())          // self-guards when no devicectl
    }

    /// Re-resolves the toolchain (e.g. after the adb path changes in Settings)
    /// and restarts discovery.
    func reloadProviders() {
        discoveryTasks.forEach { $0.cancel() }
        discoveryTasks.removeAll()
        devicesByPlatform.removeAll()
        devices = []
        buildProviders()
        startDiscovery()
    }

    // MARK: - Discovery

    func startDiscovery() {
        guard discoveryTasks.isEmpty else { return }
        for provider in providers {
            let platform = provider.platform
            let task = Task { [weak self] in
                for await list in provider.deviceStream() {
                    guard let self else { return }
                    self.devicesByPlatform[platform] = list
                    self.recomputeDevices()
                }
            }
            discoveryTasks.append(task)
        }
        // Companion discovery (mDNS) is just another device source, merged into the list.
        companionHub.onDevices = { [weak self] devices in
            guard let self else { return }
            self.companionDevices = devices
            self.persistKnownCompanions(devices)
            // Keep a control link to every discovered companion, even before capture, so the
            // desktop can configure it and push its CA automatically. connect() is idempotent.
            for d in devices where !self.companionConnectedIDs.contains(d.id) {
                self.companionHub.connect(id: d.id)
            }
            self.recomputeDevices()
        }
        companionHub.onConnectionChange = { [weak self] id, connected in
            guard let self else { return }
            if connected {
                self.companionConnectedIDs.insert(id)
                self.pushCAToCompanion(id)   // give the app the cert to install, pre-capture
            } else {
                self.companionConnectedIDs.remove(id)
                self.companionCAPushed.remove(id)   // re-push on reconnect (the app may have restarted)
            }
            self.recomputeDevices()
        }
        companionHub.onDeviceInfo = { [weak self] id, _, version in
            guard let self else { return }
            self.companionVersions[id] = version
            self.recomputeDevices()
        }
        if !uiTestMode { companionHub.startBrowsing() }
    }

    /// Match a companion advertisement ("Jaca <MODEL>") to an adb device by model name.
    private static func companionMatches(_ comp: CompanionDevice, _ device: Device) -> Bool {
        guard device.platform == .android, !device.isCompanion else { return false }
        func norm(_ s: String) -> String {
            s.replacingOccurrences(of: "Jaca", with: "").lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let n = norm(comp.name), m = norm(device.model)
        return !m.isEmpty && !n.isEmpty && (n.contains(m) || m.contains(n))
    }

    /// Whether the companion app on `companionID` is older than the bundled APK.
    private func companionNeedsUpdate(_ companionID: String) -> Bool {
        guard let v = companionVersions[companionID] else { return false }
        return CompanionVersion.updateAvailable(deviceVersion: v)
    }

    private func persistKnownCompanions(_ live: [CompanionDevice]) {
        var byID = Dictionary(uniqueKeysWithValues: knownCompanions.map { ($0.id, $0) })
        for d in live { byID[d.id] = CompanionDeviceStore.Cached(id: d.id, name: d.name) }
        knownCompanions = Array(byID.values)
        companionStore.save(knownCompanions)
    }

    private func recomputeDevices() {
        var merged = devicesByPlatform
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .flatMap { $0.value }

        // Companion is just another device source. Annotate adb devices that also
        // advertise companion (drives a green/red chip); surface companion-only and
        // previously-seen-but-offline devices as their own entries.
        var unmatched = companionDevices
        for i in merged.indices {
            if let idx = unmatched.firstIndex(where: { Self.companionMatches($0, merged[i]) }) {
                let comp = unmatched.remove(at: idx)
                merged[i].companionID = comp.id
                merged[i].companionConnected = companionConnectedIDs.contains(comp.id)
                merged[i].companionUpdateAvailable = companionNeedsUpdate(comp.id)
            }
        }
        let liveIDs = Set(companionDevices.map(\.id))
        for comp in unmatched {
            let connected = companionConnectedIDs.contains(comp.id)
            var device = Device(id: comp.id, platform: .android, model: comp.name,
                                state: connected ? .connected : .offline,
                                isCompanion: true, companionID: comp.id, companionConnected: connected)
            device.companionUpdateAvailable = companionNeedsUpdate(comp.id)
            merged.append(device)
        }
        // Previously-seen companion devices not currently advertised: show offline.
        for cached in knownCompanions where !liveIDs.contains(cached.id) {
            merged.append(Device(id: cached.id, platform: .android, model: cached.name,
                                 state: .offline, isCompanion: true, companionID: cached.id,
                                 companionConnected: false))
        }

        devices = merged
        restorePendingTabs()

        if let platform = autoSessionPlatform, sessions.isEmpty,
           let device = devices.first(where: { $0.platform == platform && $0.state.isReady }) {
            startSession(for: device)
        }
    }

    // MARK: - Tab persistence & restore

    private func restorePendingTabs() {
        guard !pendingRestores.isEmpty else { return }
        var stillPending: [TabDescriptor] = []
        isRestoring = true
        for descriptor in pendingRestores {
            guard let device = devices.first(where: {
                $0.id == descriptor.deviceID && $0.platform == descriptor.platform && $0.state.isReady
            }) else {
                stillPending.append(descriptor)
                continue
            }
            // Restore tabs STOPPED — the user presses play to stream — so a relaunch
            // never starts many sessions at once (which can overwhelm the app).
            switch descriptor.kind {
            case .log:
                var filter = LogFilter()
                filter.minLevel = LogLevel(rawValue: descriptor.minLevel) ?? .verbose
                filter.query = descriptor.query
                filter.isRegex = descriptor.isRegex
                let session = startSession(for: device, filter: filter, name: descriptor.displayName, autoStart: false)
                if !descriptor.packageLabel.isEmpty { session?.setPackage(descriptor.packageLabel) }
            case .network:
                let session = startNetworkSession(for: device, name: descriptor.displayName, autoStart: false)
                // Pre-configure the chosen mode so the tab restores ready-to-run:
                // the user just presses play (no re-picking from the chooser).
                let pkg = descriptor.packageLabel.isEmpty ? nil : descriptor.packageLabel
                let kind = descriptor.captureMode.flatMap { CaptureSourceRegistry.descriptor(id: $0)?.kind } ?? .proxy
                session?.restoreMode(kind, package: pkg)
            }
        }
        isRestoring = false
        pendingRestores = stillPending
        persistTabs()
    }

    /// Serializes open tabs (plus not-yet-restored ones) for the next launch.
    func persistTabs() {
        guard !isRestoring, !uiTestMode else { return }
        var descriptors = sessions.compactMap { Self.descriptor(for: $0) }
        // Keep tabs whose device hasn't reappeared yet so they survive a relaunch.
        for pending in pendingRestores where !descriptors.contains(where: { $0.matches(pending) }) {
            descriptors.append(pending)
        }
        if let data = try? JSONEncoder().encode(descriptors) {
            UserDefaults.standard.set(data, forKey: Self.tabsKey)
        }
    }

    private static func descriptor(for tab: any WorkspaceTab) -> TabDescriptor? {
        if let log = tab as? LogSession {
            return TabDescriptor(kind: .log, platform: log.device.platform, deviceID: log.device.id,
                                 displayName: log.displayName, minLevel: log.filter.minLevel.rawValue,
                                 query: log.filter.query, isRegex: log.filter.isRegex,
                                 packageLabel: log.filter.packageLabel)
        }
        if let net = tab as? NetworkSession {
            return TabDescriptor(kind: .network, platform: net.device.platform, deviceID: net.device.id,
                                 displayName: net.displayName, minLevel: 0, query: "",
                                 isRegex: false, packageLabel: net.targetPackage ?? "",
                                 captureMode: net.currentDescriptor?.id ?? "proxy")
        }
        return nil
    }

    private static func loadPersistedTabs() -> [TabDescriptor] {
        guard let data = UserDefaults.standard.data(forKey: tabsKey),
              let descriptors = try? JSONDecoder().decode([TabDescriptor].self, from: data) else { return [] }
        return descriptors
    }

    // MARK: - Per-device shared context

    /// Vends the shared `DeviceContext` for `device`, creating + starting it on
    /// first use. Reused across all tabs targeting the same device.
    private func context(for device: Device) -> DeviceContext {
        if let existing = deviceContexts[device.id] { return existing }
        let ctx = DeviceContext(device: device, adbURL: adbURL)
        deviceContexts[device.id] = ctx
        ctx.start()
        return ctx
    }

    /// Tears down a device's context once no remaining tab targets it.
    private func releaseContextIfUnused(_ deviceID: String) {
        let stillUsed = sessions.contains { ($0 as? LogSession)?.device.id == deviceID
            || ($0 as? NetworkSession)?.device.id == deviceID }
        if !stillUsed, let ctx = deviceContexts.removeValue(forKey: deviceID) { ctx.stop() }
    }

    // MARK: - Sessions

    @discardableResult
    func startSession(for device: Device, filter: LogFilter = LogFilter(),
                      name: String? = nil, autoStart: Bool = true) -> LogSession? {
        mode = .devices   // opening a device session returns to the devices/sessions view
        guard makeLogSource(for: device) != nil else { return nil }   // device has a usable source
        var filter = filter
        filter.exclusions = LogExclusionStore.shared.rules            // global hidden-message rules
        let store = history
        // adbURL is only used by the Android pid/clear helpers; a placeholder is
        // fine for iOS sessions (they never call those paths).
        let toolURL = adbURL ?? AppleToolchain.xcrun
        // A factory (not a fixed instance) so the session can re-spawn the tool to
        // auto-reconnect after a device/stream drop.
        let adb = adbURL
        let makeSource: @Sendable () -> LogSource? = {
            switch device.platform {
            case .android: return adb.map { AndroidLogSource(adbURL: $0, serial: device.id) }
            case .iosSimulator: return SimulatorLogSource(udid: device.id)
            case .iosDevice: return IOSDeviceLogSource(udid: device.id)
            }
        }
        let session = LogSession(
            device: device, makeSource: makeSource, adbURL: toolURL,
            filter: filter, displayName: name,
            onPersist: { sid, lines in
                Task { await store?.appendLines(sessionID: sid, lines) }
            }
        )
        let id = session.id
        session.deviceContext = context(for: device)
        session.onStateChanged = { [weak self] in self?.persistTabs() }
        // Record history on each (re)start, whether auto-started or started later.
        session.onStarted = { [weak session] in
            guard let session else { return }
            let pkg = session.filter.packageLabel
            let displayName = session.displayName
            Task {
                await store?.upsertDevice(device)
                await store?.beginSession(id: id, device: device, package: pkg, displayName: displayName)
            }
        }
        sessions.append(session)
        selectedSessionID = session.id
        if autoStart { session.start() }
        persistTabs()
        return session
    }

    private var ca: CertificateAuthority?
    /// Shared on-disk cache for older network-transaction bodies (keeps RAM flat on
    /// long-running capture sessions).
    private let bodyCache = NetworkBodyCache()

    /// The shared CA, minted (and persisted, key in the Keychain) on first use. Also feeds
    /// the onboarding web server so a phone can download and trust the cert.
    private func ensureCA() -> CertificateAuthority? {
        if let ca { return ca }
        guard let made = try? CertificateAuthority() else { return nil }
        ca = made
        return made
    }

    /// Push the desktop CA to a freshly connected companion so the app can prompt the user to
    /// install it — before any capture. Once per connection (re-sent on reconnect, since the
    /// app may have restarted and lost it).
    private func pushCAToCompanion(_ id: String) {
        guard !companionCAPushed.contains(id), let ca = ensureCA() else { return }
        companionCAPushed.insert(id)
        companionHub.installCa(id: id, pem: Data(ca.rootCertificatePEM.utf8))
    }

    @discardableResult
    func startNetworkSession(for device: Device, name: String? = nil, autoStart: Bool = true) -> NetworkSession? {
        mode = .devices   // opening a session returns to the devices/sessions view
        guard let authority = ensureCA() else { return nil }
        let session = NetworkSession(device: device, ca: authority, adbURL: adbURL,
                                     displayName: name, bodyCache: bodyCache, companion: companionHub)
        session.deviceContext = context(for: device)
        session.onStateChanged = { [weak self] in self?.persistTabs() }
        // Companion-only devices have no proxy/agent path — pre-select companion so the
        // tab is ready to stream (the network inspection "just knows").
        if device.isCompanion { session.restoreMode(.companion, package: nil) }
        sessions.append(session)
        selectedSessionID = session.id
        if autoStart { session.start() }
        persistTabs()
        return session
    }

    // MARK: - Stranded device proxy (cleanup backstop)

    /// The device's current global HTTP proxy if it points at this Mac — a proxy left
    /// behind by an older proxy-mode Jaca. Drives the sidebar "Revert" one-click fix.
    /// (Companion capture never sets a device proxy, so this only cleans up legacy state.)
    func strandedProxy(for device: Device) async -> String? {
        guard device.platform == .android, let adbURL else { return nil }
        guard let current = await ProxyConfigurator.currentAndroidProxy(adbURL: adbURL, serial: device.id) else {
            return nil
        }
        let ours = ProxyConfigurator.hostAddress(for: device)
        return ProxyConfigurator.proxyHost(current) == ours ? current : nil
    }

    /// Clears the device's global HTTP proxy — the sidebar "Revert" action.
    func revertDeviceProxy(_ device: Device) async {
        guard device.platform == .android, let adbURL else { return }
        await ProxyConfigurator.clearAndroidProxy(adbURL: adbURL, serial: device.id)
    }

    private func makeLogSource(for device: Device) -> LogSource? {
        switch device.platform {
        case .android:
            guard let adbURL else { return nil }
            return AndroidLogSource(adbURL: adbURL, serial: device.id)
        case .iosSimulator:
            return SimulatorLogSource(udid: device.id)
        case .iosDevice:
            return IOSDeviceLogSource(udid: device.id)
        }
    }

    func closeSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].stop()
        if sessions[index] is LogSession {
            let store = history
            Task { await store?.endSession(id: id) }
        }
        let deviceID = (sessions[index] as? LogSession)?.device.id
            ?? (sessions[index] as? NetworkSession)?.device.id
        sessions.remove(at: index)
        if let deviceID { releaseContextIfUnused(deviceID) }
        if selectedSessionID == id {
            selectedSessionID = sessions[safe: index]?.id ?? sessions.last?.id
        }
        persistTabs()
    }

    func select(_ id: UUID) { selectedSessionID = id }

    /// Reorders tabs: move the dragged session to the target's position.
    func moveSession(dragging id: UUID, over targetID: UUID) {
        guard id != targetID,
              let from = sessions.firstIndex(where: { $0.id == id }),
              let to = sessions.firstIndex(where: { $0.id == targetID }) else { return }
        let item = sessions.remove(at: from)
        sessions.insert(item, at: to)
        persistTabs()
    }

    /// Cycles the selected tab (Shift+Tab), wrapping around.
    func cycleTab(forward: Bool) {
        guard !sessions.isEmpty else { return }
        let ids = sessions.map(\.id)
        let current = selectedSessionID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = forward ? (current + 1) % ids.count : (current - 1 + ids.count) % ids.count
        selectedSessionID = ids[next]
    }
}

/// Lightweight, Codable snapshot of a tab for session restore.
struct TabDescriptor: Codable {
    enum Kind: String, Codable { case log, network }
    var kind: Kind
    var platform: DevicePlatform
    var deviceID: String
    var displayName: String
    var minLevel: Int
    var query: String
    var isRegex: Bool
    var packageLabel: String
    /// Network tabs only: "proxy" or "agent". Optional so tabs persisted before
    /// this field still decode (defaults to proxy on restore).
    var captureMode: String?

    func matches(_ other: TabDescriptor) -> Bool {
        kind == other.kind && deviceID == other.deviceID && displayName == other.displayName
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
