import Foundation
import Observation

/// Root app state: the merged live device list and the ordered set of log
/// sessions (tabs). Providers are pluggable, so iOS slots in by appending another
/// `DeviceProvider` and a matching `LogSource` in `startSession`.
@MainActor
@Observable
final class AppModel {
    private(set) var devices: [Device] = []
    private(set) var sessions: [any WorkspaceTab] = []
    var selectedSessionID: UUID?

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

    init() {
        history = HistoryStore()
        if let days = UserDefaults.standard.object(forKey: "retentionDays") as? Int, days > 0 {
            retention = TimeInterval(days) * 86_400
        }
        buildProviders()
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
    }

    // MARK: - Sessions

    @discardableResult
    func startSession(for device: Device, filter: LogFilter = LogFilter(), name: String? = nil) -> LogSession? {
        guard let source = makeLogSource(for: device) else { return nil }
        let store = history
        // adbURL is only used by the Android pid/clear helpers; a placeholder is
        // fine for iOS sessions (they never call those paths).
        let toolURL = adbURL ?? AppleToolchain.xcrun
        let session = LogSession(
            device: device, source: source, adbURL: toolURL,
            filter: filter, displayName: name,
            onPersist: { sid, lines in
                Task { await store?.appendLines(sessionID: sid, lines) }
            }
        )
        sessions.append(session)
        selectedSessionID = session.id
        let pkg = filter.packageLabel
        let displayName = session.displayName
        let id = session.id
        Task {
            await store?.upsertDevice(device)
            await store?.beginSession(id: id, device: device, package: pkg, displayName: displayName)
        }
        session.start()
        return session
    }

    private var ca: CertificateAuthority?

    @discardableResult
    func startNetworkSession(for device: Device, name: String? = nil) -> NetworkSession? {
        let authority: CertificateAuthority
        if let ca { authority = ca }
        else {
            guard let made = try? CertificateAuthority() else { return nil }
            ca = made
            authority = made
        }
        let session = NetworkSession(device: device, ca: authority, adbURL: adbURL, displayName: name)
        sessions.append(session)
        selectedSessionID = session.id
        session.start()
        return session
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
    }

    func select(_ id: UUID) { selectedSessionID = id }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
