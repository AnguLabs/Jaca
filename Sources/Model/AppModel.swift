import Foundation
import Observation

/// The two top-level areas of the app.
enum WorkspaceMode: String { case devices, worktrees }

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

    /// The single, persisted worktrees area state.
    let worktrees = WorktreesModel()

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
        if !uiTestMode { pendingRestores = Self.loadPersistedTabs() }
        buildProviders()
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
    }

    private func recomputeDevices() {
        devices = devicesByPlatform
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .flatMap { $0.value }
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
                if !descriptor.packageLabel.isEmpty { session?.targetPackage = descriptor.packageLabel }
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
                                 isRegex: false, packageLabel: net.targetPackage ?? "")
        }
        return nil
    }

    private static func loadPersistedTabs() -> [TabDescriptor] {
        guard let data = UserDefaults.standard.data(forKey: tabsKey),
              let descriptors = try? JSONDecoder().decode([TabDescriptor].self, from: data) else { return [] }
        return descriptors
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

    @discardableResult
    func startNetworkSession(for device: Device, name: String? = nil, autoStart: Bool = true) -> NetworkSession? {
        mode = .devices   // opening a session returns to the devices/sessions view
        let authority: CertificateAuthority
        if let ca { authority = ca }
        else {
            guard let made = try? CertificateAuthority() else { return nil }
            ca = made
            authority = made
        }
        let session = NetworkSession(device: device, ca: authority, adbURL: adbURL,
                                     displayName: name, bodyCache: bodyCache)
        session.onStateChanged = { [weak self] in self?.persistTabs() }
        sessions.append(session)
        selectedSessionID = session.id
        if autoStart { session.start() }
        persistTabs()
        return session
    }

    // MARK: - Stranded device proxy (cleanup backstop)

    /// The device's current global HTTP proxy if it looks like one Jaca set (its
    /// host is this Mac) and no live session is actively using it — i.e. a proxy
    /// left behind by a kill/crash that the teardown couldn't revert. nil otherwise.
    /// Drives the sidebar "Revert" affordance so a stranded proxy is a one-click fix.
    func strandedProxy(for device: Device) async -> String? {
        guard device.platform == .android, let adbURL else { return nil }
        let activelyUsed = sessions.contains { tab in
            (tab as? NetworkSession).map { $0.proxyConfigured && $0.device.id == device.id } ?? false
        }
        if activelyUsed { return nil }
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
        sessions.remove(at: index)
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

    func matches(_ other: TabDescriptor) -> Bool {
        kind == other.kind && deviceID == other.deviceID && displayName == other.displayName
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
