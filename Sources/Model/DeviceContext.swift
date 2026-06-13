import Foundation
import Observation

/// Per-device shared state, vended by `AppModel` and reused by **every** tab
/// (log + network) targeting the same device. Package discovery and capability
/// probing happen once per device instead of once per tab, so two tabs on the
/// same emulator share one polling loop and one app list.
///
/// Lifecycle is ref-counted by `AppModel`: created with the first tab for a
/// device, polling runs while referenced, torn down when the last tab closes.
@MainActor
@Observable
final class DeviceContext {
    let device: Device
    let adbURL: URL?

    /// Probed once on `start()`; nil until it resolves (or on non-Android).
    private(set) var capabilities: AndroidCapabilities?
    /// Installed apps, background-polled and shared across tabs.
    private(set) var apps: [AppEntry] = []
    /// Package ids the in-process agent can attach to (debuggable). Cached.
    private(set) var debuggable: Set<String> = []
    private(set) var appsLoaded = false

    private var pollTask: Task<Void, Never>?
    private var debugCheckTask: Task<Void, Never>?
    private var checkedDebuggable: Set<String> = []

    init(device: Device, adbURL: URL?) {
        self.device = device
        self.adbURL = adbURL
    }

    /// Begins capability probing + app polling. Idempotent.
    func start() {
        guard pollTask == nil else { return }
        if device.platform == .android, let adbURL {
            Task { [weak self] in
                let caps = await AndroidCapabilityProbe.probe(adbURL: adbURL, serial: device.id)
                self?.capabilities = caps
            }
        }
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        debugCheckTask?.cancel(); debugCheckTask = nil
    }

    /// Forces an immediate app refresh (e.g. the user opened the app picker).
    func refreshApps() {
        Task { [weak self] in
            guard let self else { return }
            self.apply(await InstalledApps.list(for: self.device, adbURL: self.adbURL))
        }
    }

    /// Polls fast until apps appear, then backs off — cheap shared discovery.
    private func pollLoop() async {
        while !Task.isCancelled {
            apply(await InstalledApps.list(for: device, adbURL: adbURL))
            try? await Task.sleep(for: appsLoaded ? .seconds(15) : .seconds(1))
        }
    }

    private func apply(_ list: [AppEntry]) {
        guard !list.isEmpty else { return }
        apps = list
        appsLoaded = true
        checkDebuggable(for: list)
    }

    /// Resolves debuggability for Android user apps not yet checked (one run-as per
    /// app), caching results so we don't re-probe every poll.
    private func checkDebuggable(for list: [AppEntry]) {
        guard device.platform == .android, let adbURL, debugCheckTask == nil else { return }
        let toCheck = list.filter { $0.isUserApp && !checkedDebuggable.contains($0.id) }
        guard !toCheck.isEmpty else { return }
        let serial = device.id
        debugCheckTask = Task { [weak self] in
            var found = Set<String>()
            await withTaskGroup(of: (String, Bool).self) { group in
                for app in toCheck {
                    group.addTask {
                        (app.id, await AgentController.isDebuggable(adbURL: adbURL, serial: serial, package: app.id))
                    }
                }
                for await (id, ok) in group { if ok { found.insert(id) } }
            }
            guard let self else { return }
            toCheck.forEach { self.checkedDebuggable.insert($0.id) }
            self.debuggable.formUnion(found)
            self.debugCheckTask = nil
        }
    }
}
