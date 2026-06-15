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

/// Monotonic, thread-safe id source. The session stamps every line (and marker)
/// with it so ids stay unique + ordered across stream reconnects (each `LogSource`
/// restart would otherwise reset its own seq to 0).
final class SeqCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; let v = value; value &+= 1; return v }
}

/// One tab: a single running (or stopped) log stream bound to a device + filter,
/// with an editable display name. Incoming lines accumulate off-main and are
/// coalesced into the observed `visible` slice on a ~30ms timer to stay smooth
/// under thousands of lines/sec.
@MainActor
@Observable
final class LogSession: WorkspaceTab {
    let id = UUID()
    var displayName: String { didSet { onStateChanged?() } }
    let device: Device

    /// Called when persisted state (filter/package/name) changes, so the open-tabs
    /// snapshot is saved immediately rather than only on quit.
    var onStateChanged: (() -> Void)?

    private(set) var filter: LogFilter
    private(set) var isRunning = false
    private(set) var isConnecting = false
    private(set) var visible: [LogLine] = []
    private(set) var totalCount = 0
    private(set) var droppedCount = 0
    /// Bumped whenever `visible` is replaced wholesale (clear / filter change) — as
    /// opposed to an append. The virtualized list uses it to choose a full reload vs
    /// a cheap row-count update.
    private(set) var listEpoch = 0
    /// Seqs of detected crashes (FATAL EXCEPTION / native fatal), oldest→newest.
    private(set) var crashSeqs: [UInt64] = []
    /// Which crash the up/down navigation is currently on (nil = none selected yet).
    private(set) var crashCursor: Int?
    var crashCount: Int { crashSeqs.count }
    var lastCrashSeq: UInt64? { crashSeqs.last }
    /// Set to a line seq to request the list scroll to it (crash navigation).
    var scrollTarget: UInt64?
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

    private let makeSource: @Sendable () -> LogSource?
    private var source: LogSource?
    /// Optional secondary source that captures the targeted app's stdout/print
    /// (simulator `--console-pty`). Built per-bundle, so it's a factory taking the
    /// current package; nil on platforms without a stdout tap (Android, real iOS).
    private let makeConsoleSource: (@Sendable (_ bundleID: String) -> LogSource?)?
    private var consoleSource: LogSource?
    private let seq = SeqCounter()
    let adbURL: URL
    private let onPersist: (@Sendable (UUID, [LogLine]) -> Void)?

    // Package liveness, for death/restart markers.
    private var appWasAlive = false
    private var sawAppAlive = false

    private var ring: [LogLine] = []
    // Virtualized rendering makes display cost independent of buffer size, so we keep
    // a large scrollback and drop far less. (Memory ≈ this × ~300 B.)
    private let ringCap = 500_000
    private let maxPerFlush = 4_000           // bound main-thread work per tick
    private var compiledRegex: NSRegularExpression?
    private var recomputeToken = 0
    /// Every PID the filtered package has had this session. We accumulate and never
    /// clear it, so a crashing/relaunching app keeps showing its logs (incl. the crash).
    private var accumulatedPids: Set<Int32> = []

    private let pending = LineBuffer()
    private var consumeTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pidTask: Task<Void, Never>?
    private var consoleTask: Task<Void, Never>?

    init(
        device: Device,
        makeSource: @escaping @Sendable () -> LogSource?,
        adbURL: URL,
        filter: LogFilter = LogFilter(),
        displayName: String? = nil,
        makeConsoleSource: (@Sendable (_ bundleID: String) -> LogSource?)? = nil,
        onPersist: (@Sendable (UUID, [LogLine]) -> Void)? = nil
    ) {
        self.device = device
        self.makeSource = makeSource
        self.makeConsoleSource = makeConsoleSource
        self.adbURL = adbURL
        self.filter = filter
        self.onPersist = onPersist
        self.displayName = displayName ?? device.displayModel
        self.compiledRegex = filter.compiledRegex()
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        statusMessage = nil
        onStarted?()
        startFlushLoop()
        restartPIDPollingIfNeeded()
        restartConsoleCaptureIfNeeded()
        consumeTask = Task.detached(priority: .utility) { [weak self] in
            await self?.consumeLoop()
        }
    }

    /// Connects the source and streams; if the stream ends while we're still running
    /// (device unplugged, adb restarted, …) it injects a reconnect marker and retries
    /// forever — automatic reconnection. Every line is re-stamped with our monotonic
    /// seq so ids stay unique across reconnects.
    private func consumeLoop() async {
        let buffer = pending, counter = seq
        var disconnected = false
        while await isRunning, !Task.isCancelled {
            guard let stream = await openStream() else {   // couldn't spawn the tool
                if !disconnected { injectMarker("✕ can’t reach \(device.displayModel) — retrying…"); disconnected = true }
                try? await Task.sleep(for: .seconds(2)); continue
            }
            if disconnected { injectMarker("✓ \(device.displayModel) reconnected"); disconnected = false }
            for await line in stream {
                var l = line; l.seq = counter.next(); buffer.append(l)
            }
            // stream ended
            guard await isRunning, !Task.isCancelled else { break }
            injectMarker("✕ log stream to \(device.displayModel) lost — reconnecting…")
            disconnected = true
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func openStream() -> AsyncStream<LogLine>? {
        let s = makeSource()
        source = s
        return try? s?.start()
    }

    /// Injects a synthetic, always-visible marker line (thread-safe; callable off-main).
    nonisolated func injectMarker(_ message: String, critical: Bool = false) {
        var m = LogLine.marker(message, critical: critical)
        m.seq = seq.next()
        pending.append(m)
    }

    /// Navigate to the next crash (downward / newer). With nothing selected yet it
    /// jumps to the first; it wraps to the top after the last.
    func nextCrash() { moveCrash(forward: true) }
    /// Navigate to the previous crash (upward / older). With nothing selected it jumps
    /// to the last; it wraps to the bottom before the first.
    func previousCrash() { moveCrash(forward: false) }

    private func moveCrash(forward: Bool) {
        guard let target = Self.nextCrashIndex(cursor: crashCursor, count: crashSeqs.count, forward: forward)
        else { return }
        crashCursor = target
        followTail = false
        scrollTarget = crashSeqs[target]
    }

    /// Cycling crash index: nil + forward → first, nil + back → last; otherwise step
    /// and wrap. Returns nil when there are no crashes.
    nonisolated static func nextCrashIndex(cursor: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        if let c = cursor { return forward ? (c + 1) % count : (c - 1 + count) % count }
        return forward ? 0 : count - 1
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        source?.stop(); source = nil
        consoleSource?.stop(); consoleSource = nil
        consumeTask?.cancel(); consumeTask = nil
        flushTask?.cancel(); flushTask = nil
        pidTask?.cancel(); pidTask = nil
        consoleTask?.cancel(); consoleTask = nil
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
            // iOS uses xcrun, not adb — `adbURL` is the adb path when the Android SDK
            // is installed, which would make `adb simctl …` fail.
            let r = try? await CommandRunner.run(AppleToolchain.xcrun, ["simctl", "list", "devices", "booted"])
            return r?.stdout.contains(device.id) ?? false
        case .iosDevice:
            let r = try? await CommandRunner.run(AppleToolchain.xcrun, ["devicectl", "list", "devices"])
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
        crashSeqs.removeAll()
        crashCursor = nil
        listEpoch &+= 1
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
    func setHideSystemLogs(_ on: Bool) { mutateFilter { $0.hideSystemLogs = on } }

    /// Applies the global message-exclusion rules and re-filters (no persist callback —
    /// the rules live in `LogExclusionStore`, not the per-tab descriptor).
    func applyExclusions(_ rules: [LogExcludeRule]) {
        filter.exclusions = rules
        compiledRegex = filter.compiledRegex()
        recomputeVisible()
    }

    /// Sets the package filter: stores the label and (re)starts PID polling so the
    /// filter survives the app being killed/relaunched (PIDs change).
    func setPackage(_ package: String) {
        accumulatedPids.removeAll()   // new target → forget the previous app's PIDs
        appWasAlive = false; sawAppAlive = false
        mutateFilter {
            $0.packageLabel = package
            switch device.platform {
            case .android, .iosSimulator:
                // Both filter by PID — the bundle id never appears as the process name
                // on iOS, but the unified log carries the process id (resolved below).
                $0.pids = package.isEmpty ? nil : []
                $0.processNameQuery = ""
            case .iosDevice:
                // No easy pid map for physical devices — substring on process/subsystem.
                $0.processNameQuery = package
                $0.pids = nil
            }
        }
        restartPIDPollingIfNeeded()
        restartConsoleCaptureIfNeeded()
    }

    private func mutateFilter(_ change: (inout LogFilter) -> Void) {
        change(&filter)
        compiledRegex = filter.compiledRegex()
        recomputeVisible()
        onStateChanged?()   // persist filter/package changes right away
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
                self.listEpoch &+= 1
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
            if CrashDetector.isCrash(line) {
                crashSeqs.append(line.seq)
                injectMarker("💥 \(CrashDetector.label(line))", critical: true)
            }
        }
    }

    /// Polls `pidof <package>` while a package filter is active, updating the PID
    /// set live so app restarts keep being captured.
    private func restartPIDPollingIfNeeded() {
        pidTask?.cancel(); pidTask = nil
        guard isRunning, !filter.packageLabel.isEmpty else { return }
        let url = adbURL, serial = device.id, package = filter.packageLabel
        let resolve: @Sendable () async -> Set<Int32>
        switch device.platform {
        case .android:
            resolve = { await AndroidLogSource.resolvePIDs(adbURL: url, serial: serial, package: package) }
        case .iosSimulator:
            resolve = { await SimulatorLogSource.resolvePIDs(udid: serial, bundleID: package) }
        case .iosDevice:
            return   // physical iOS uses substring matching, no pid polling
        }
        pidTask = Task { [weak self] in
            while !Task.isCancelled {
                let resolved = await resolve()
                guard let self, !Task.isCancelled else { return }

                // Mark death / restart so it's unmissable in the log.
                let isAlive = !resolved.isEmpty
                if isAlive {
                    if !self.appWasAlive && self.sawAppAlive {
                        let pids = resolved.sorted().map(String.init).joined(separator: ", ")
                        self.injectMarker("▶︎ \(package) restarted — pid \(pids)")
                    }
                    self.sawAppAlive = true
                } else if self.appWasAlive {
                    self.injectMarker("■ \(package) terminated")
                }
                self.appWasAlive = isAlive

                // Accumulate; never clear. If the app is dead (resolved empty) we keep
                // the known PIDs so its logs stay visible. New PIDs (relaunch) are added.
                let next = Self.accumulatePIDs(self.accumulatedPids, with: resolved)
                if next != self.accumulatedPids {
                    self.accumulatedPids = next
                    self.filter.pids = next
                    self.recomputeVisible()
                }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    /// Simulator stdout/print capture: when a bundle is targeted, launch it under a
    /// PTY (`simctl launch --console-pty`) and fold its stdout/stderr — the only place
    /// `print()`/`println` output appears — into this session alongside the OSLog
    /// stream. Re-targets when the package changes; (re)launches the app each time, by
    /// design. No-op on platforms without a stdout tap (`makeConsoleSource == nil`).
    private func restartConsoleCaptureIfNeeded() {
        consoleTask?.cancel(); consoleTask = nil
        consoleSource?.stop(); consoleSource = nil
        guard isRunning, let make = makeConsoleSource else { return }
        let bundle = filter.packageLabel
        guard !bundle.isEmpty, let src = make(bundle) else { return }
        guard let stream = try? src.start() else {
            injectMarker("✕ couldn’t launch \(bundle) for stdout/print capture")
            return
        }
        consoleSource = src
        injectMarker("▶︎ capturing stdout/print from \(bundle) (app relaunched)")
        let buffer = pending, counter = seq
        consoleTask = Task.detached(priority: .utility) {
            for await line in stream {
                var l = line; l.seq = counter.next(); buffer.append(l)
            }
        }
    }

    /// Accumulates an app's PIDs across restarts. An empty `resolved` (the app died /
    /// is being reinstalled) keeps the current set, so its logs are never hidden; new
    /// PIDs from a relaunch/reinstall are added.
    nonisolated static func accumulatePIDs(_ current: Set<Int32>, with resolved: Set<Int32>) -> Set<Int32> {
        resolved.isEmpty ? current : current.union(resolved)
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
