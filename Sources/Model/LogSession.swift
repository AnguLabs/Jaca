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

    func drain() -> [LogLine] {
        lock.lock(); defer { lock.unlock() }
        let out = lines
        lines.removeAll(keepingCapacity: true)
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
    private var compiledRegex: NSRegularExpression?

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
        flush()  // drain remaining
    }

    func toggle() { isRunning ? stop() : start() }

    /// Clears the in-app scrollback (does not touch the device buffer).
    func clear() {
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

    private func recomputeVisible() {
        visible = ring.filter { filter.matches($0, regex: compiledRegex) }
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

    private func flush() {
        let batch = pending.drain()
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
