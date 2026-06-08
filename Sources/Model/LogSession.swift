import Foundation
import Observation

/// Thread-safe hand-off buffer between the background stream consumer and the
/// main-actor flush loop, so we never mutate `@Observable` state per line.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [LogLine] = []

    func append(_ line: LogLine) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    /// Drains up to `max` lines (oldest first), leaving any remainder for the next
    /// tick so a big burst is spread across flushes instead of one main-thread hit.
    func drain(max: Int) -> [LogLine] {
        lock.lock(); defer { lock.unlock() }
        if lines.count <= max {
            let out = lines
            lines.removeAll(keepingCapacity: true)
            return out
        }
        let out = Array(lines.prefix(max))
        lines.removeFirst(max)
        return out
    }
}

/// One tab: a single running (or stopped) log stream bound to a device + filter,
/// with an editable display name. Incoming lines accumulate off-main and are
/// coalesced into the observed `visible` slice on a ~30ms timer to stay smooth
/// under thousands of lines/sec.
@MainActor
@Observable
final class LogSession: WorkspaceTab {
    let id = UUID()
    var displayName: String
    let device: Device

    private(set) var filter: LogFilter
    private(set) var isRunning = false
    private(set) var isConnecting = false
    private(set) var visible: [LogLine] = []
    private(set) var totalCount = 0
    private(set) var droppedCount = 0
    var followTail = true
    var statusMessage: String?

    /// Invoked each time the stream starts (so history recording works whether the
    /// tab is auto-started or started later by the user).
    var onStarted: (() -> Void)?

    /// Subtitle for the tab/strip: device model + active filter summary.
    var subtitle: String {
        var parts = [device.displayModel]
        if !filter.packageLabel.isEmpty { parts.append(filter.packageLabel) }
        if !filter.query.isEmpty { parts.append("“\(filter.query)”") }
        if filter.minLevel != .verbose { parts.append("≥\(filter.minLevel.short)") }
        return parts.joined(separator: " · ")
    }

    private let source: LogSource
    let adbURL: URL
    private let onPersist: (@Sendable (UUID, [LogLine]) -> Void)?

    private var ring: [LogLine] = []
    private let ringCap = 100_000
    private let maxPerFlush = 4_000           // bound main-thread work per tick
    private var compiledRegex: NSRegularExpression?
    private var recomputeToken = 0

    private let pending = LineBuffer()
    private var consumeTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pidTask: Task<Void, Never>?

    init(
        device: Device,
        source: LogSource,
        adbURL: URL,
        filter: LogFilter = LogFilter(),
        displayName: String? = nil,
        onPersist: (@Sendable (UUID, [LogLine]) -> Void)? = nil
    ) {
        self.device = device
        self.source = source
        self.adbURL = adbURL
        self.filter = filter
        self.onPersist = onPersist
        self.displayName = displayName ?? device.displayModel
        self.compiledRegex = filter.compiledRegex()
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        do {
            let stream = try source.start()
            isRunning = true
            statusMessage = nil
            onStarted?()
            let buffer = pending
            consumeTask = Task.detached(priority: .utility) {
                for await line in stream {
                    buffer.append(line)
                }
            }
            startFlushLoop()
            restartPIDPollingIfNeeded()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        source.stop()
        consumeTask?.cancel(); consumeTask = nil
        flushTask?.cancel(); flushTask = nil
        pidTask?.cancel(); pidTask = nil
        flush(max: .max)  // drain everything that's left
    }

    func toggle() { isRunning ? stop() : connect() }

    /// Verifies the device is reachable (and, for Android, that a filtered package
    /// is installed) before starting the stream, surfacing a clear message if not.
    /// Used by restored/stopped tabs to (re)connect with feedback.
    func connect() {
        guard !isRunning, !isConnecting else { return }
        isConnecting = true
        statusMessage = nil
        Task { @MainActor in
            let available = await checkDeviceAvailable()
            guard available else {
                isConnecting = false
                statusMessage = deviceUnavailableMessage
                return
            }
            // Soft check: warn (but still connect) if a filtered package is missing.
            if device.platform == .android, !filter.packageLabel.isEmpty,
               await !isPackageInstalled(filter.packageLabel) {
                statusMessage = "App “\(filter.packageLabel)” isn’t installed on \(device.displayModel)."
            }
            isConnecting = false
            start()
        }
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
            let r = try? await CommandRunner.run(adbURL, ["-s", device.id, "get-state"])
            return r?.exitCode == 0 && (r?.stdout.contains("device") ?? false)
        case .iosSimulator:
            let r = try? await CommandRunner.run(adbURL, ["simctl", "list", "devices", "booted"])
            return r?.stdout.contains(device.id) ?? false
        case .iosDevice:
            let r = try? await CommandRunner.run(adbURL, ["devicectl", "list", "devices"])
            return r?.stdout.contains(device.id) ?? false
        }
    }

    private func isPackageInstalled(_ package: String) async -> Bool {
        let r = try? await CommandRunner.run(adbURL, ["-s", device.id, "shell", "pm", "list", "packages", package])
        return r?.stdout.contains("package:\(package)") ?? false
    }

    /// Clears the in-app scrollback (does not touch the device buffer).
    func clear() {
        recomputeToken &+= 1   // invalidate any in-flight background recompute
        ring.removeAll(keepingCapacity: true)
        visible.removeAll(keepingCapacity: true)
        totalCount = 0
        droppedCount = 0
    }

    /// Clears the device-side logcat buffer too (`adb logcat -c`).
    func clearDeviceBuffer() {
        clear()
        let url = adbURL, serial = device.id
        Task.detached { await AndroidLogSource.clearBuffer(adbURL: url, serial: serial) }
    }

    // MARK: - Filtering

    func setMinLevel(_ level: LogLevel) { mutateFilter { $0.minLevel = level } }
    func setRegex(_ on: Bool) { mutateFilter { $0.isRegex = on } }
    func setQuery(_ text: String) { mutateFilter { $0.query = text } }

    /// Sets the package filter: stores the label and (re)starts PID polling so the
    /// filter survives the app being killed/relaunched (PIDs change).
    func setPackage(_ package: String) {
        mutateFilter {
            $0.packageLabel = package
            switch device.platform {
            case .android:
                $0.pids = package.isEmpty ? nil : []
                $0.processNameQuery = ""
            case .iosSimulator, .iosDevice:
                // No pidof on iOS — filter by process/subsystem substring instead.
                $0.processNameQuery = package
                $0.pids = nil
            }
        }
        restartPIDPollingIfNeeded()
    }

    private func mutateFilter(_ change: (inout LogFilter) -> Void) {
        change(&filter)
        compiledRegex = filter.compiledRegex()
        recomputeVisible()
    }

    /// Re-filters the whole ring off the main thread (it can be 100k lines), then
    /// assigns on main — so changing the level/query/package never freezes the UI.
    /// A token discards stale results; a catch-up pass re-adds lines that streamed
    /// in while the background filter ran.
    private func recomputeVisible() {
        recomputeToken &+= 1
        let token = recomputeToken
        let snapshot = ring
        let f = filter
        let lastSeq = snapshot.last?.seq
        Task.detached(priority: .userInitiated) {
            let regex = f.compiledRegex()
            let result = snapshot.filter { f.matches($0, regex: regex) }
            await MainActor.run { [weak self] in
                guard let self, token == self.recomputeToken else { return }
                var out = result
                if let lastSeq {
                    for line in self.ring where line.seq > lastSeq
                        && self.filter.matches(line, regex: self.compiledRegex) {
                        out.append(line)
                    }
                } else {
                    out = self.ring.filter { self.filter.matches($0, regex: self.compiledRegex) }
                }
                self.visible = out
            }
        }
    }

    // MARK: - Internals

    private func startFlushLoop() {
        flushTask = Task { [weak self] in
            while let self, self.isRunning, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                self.flush()
            }
        }
    }

    private func flush(max: Int = 4_000) {
        let batch = pending.drain(max: max)
        guard !batch.isEmpty else { return }
        onPersist?(id, batch)

        ring.append(contentsOf: batch)
        totalCount += batch.count

        if ring.count > ringCap {
            let overflow = ring.count - ringCap
            ring.removeFirst(overflow)
            droppedCount += overflow
            let minSeq = ring.first?.seq ?? 0
            var drop = 0
            while drop < visible.count && visible[drop].seq < minSeq { drop += 1 }
            if drop > 0 { visible.removeFirst(drop) }
        }
        for line in batch where filter.matches(line, regex: compiledRegex) {
            visible.append(line)
        }
    }

    /// Polls `pidof <package>` while a package filter is active, updating the PID
    /// set live so app restarts keep being captured.
    private func restartPIDPollingIfNeeded() {
        pidTask?.cancel(); pidTask = nil
        guard device.platform == .android, isRunning, !filter.packageLabel.isEmpty else { return }
        let url = adbURL, serial = device.id, package = filter.packageLabel
        pidTask = Task { [weak self] in
            while !Task.isCancelled {
                let pids = await AndroidLogSource.resolvePIDs(adbURL: url, serial: serial, package: package)
                guard let self, !Task.isCancelled else { return }
                if self.filter.pids != pids {
                    self.filter.pids = pids
                    self.recomputeVisible()
                }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    /// Installed apps/packages on this device, for the filter dropdown.
    func installedApps() async -> [AppEntry] {
        await InstalledApps.list(for: device, adbURL: adbURL)
    }

    // MARK: - Export

    func exportText() -> String {
        visible.map { $0.raw }.joined(separator: "\n")
    }
}
