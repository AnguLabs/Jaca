import Foundation

/// Parses one line from a physical-device console launch into a `LogLine`.
///
/// Launching the app with `OS_ACTIVITY_DT_MODE=enable` makes the OS mirror every
/// `os_log`/`NSLog`/`CFLog` message to the process's stderr — fully formatted and
/// **un-redacted** (the values that the passive syslog relay shows as `<private>`).
/// `print()`/`println` lands on stdout. Capturing both fds therefore yields the
/// same content the Xcode console shows, without a debugger or a logging profile.
///
/// Two line shapes arrive:
///   • the os_log mirror — `2026-06-15 16:56:41.265-0300 Teya Dev[5904:1882516] [cat] msg`
///   • raw stdout/stderr — anything without that header (genuine `print()` output)
/// plus a little `devicectl` chrome at launch, which we drop.
enum IOSDeviceConsoleParser {
    /// `<date time.frac±zone> <process>[<pid>:<tid>] [<subsystem>] <message>`
    private static let mirror = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+[-+]\d{4}) (.+?)\[(\d+):[0-9a-fx]+\] \[(.*?)\] (.*)$"#
    )

    /// `devicectl`'s own status lines (`16:56:40  Acquired tunnel…`, plus the launch
    /// banner) — not app output, so they're dropped.
    private static let chrome = try! NSRegularExpression(
        pattern: #"^(\d{2}:\d{2}:\d{2}  |Launched application with |Waiting for the application to terminate)"#
    )

    static func parse(_ raw: String) -> LogLine? {
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let full = NSRange(line.startIndex..<line.endIndex, in: line)

        if chrome.firstMatch(in: line, range: full) != nil { return nil }

        if let m = mirror.firstMatch(in: line, range: full) {
            func g(_ i: Int) -> String {
                guard let r = Range(m.range(at: i), in: line) else { return "" }
                return String(line[r])
            }
            let process = g(2)
            let subsystem = g(4)                      // may be empty (the app's own Logger)
            var level: LogLevel = .info               // the DT mirror carries no level token…
            var tag = subsystem.isEmpty ? process : subsystem
            var message = g(5)
            // …so recover it from the leading status glyph apps prefix their Logger
            // output with (🟢/🟡/🔴/…), and lift the following `(Category)` into the tag
            // so the device view reads like the simulator's. Framework lines have no
            // glyph and stay at Info with their bracketed subsystem as the tag.
            if let (glyphLevel, afterGlyph) = Self.levelFromGlyph(message) {
                level = glyphLevel
                message = afterGlyph
                if let (category, afterCategory) = Self.leadingCategory(message) {
                    tag = category
                    message = afterCategory
                }
            }
            return LogLine(
                seq: 0,
                timestamp: Self.formatter.date(from: g(1)) ?? Date(),
                level: level,
                tag: tag,
                pid: Int32(g(3)) ?? 0,
                tid: 0,
                message: message,
                raw: raw,
                processName: process
            )
        }

        // Genuine stdout/stderr (print/println) — never reaches the unified log.
        return LogLine(
            seq: 0,
            timestamp: Date(),
            level: .info,
            tag: "stdout",
            pid: 0,
            tid: 0,
            message: line,
            raw: raw,
            processName: nil,
            isConsoleOutput: true
        )
    }

    /// A leading colored-circle level glyph → level, plus the message with the glyph
    /// (and any following space) removed. Returns nil when there's no known glyph.
    private static func levelFromGlyph(_ message: String) -> (LogLevel, String)? {
        let map: [Character: LogLevel] = [
            "🔴": .error, "🟠": .warn, "🟡": .warn,
            "🟢": .info, "🔵": .debug, "⚪": .debug,
        ]
        guard let first = message.first, let level = map[first] else { return nil }
        return (level, String(message.dropFirst().drop(while: { $0 == " " })))
    }

    /// A leading `(Category)` token (the app's Logger category) → (category, rest).
    /// Categories are identifiers, so a token containing whitespace is rejected.
    private static func leadingCategory(_ message: String) -> (String, String)? {
        guard message.hasPrefix("("), let close = message.firstIndex(of: ")") else { return nil }
        let category = String(message[message.index(after: message.startIndex)..<close])
        guard !category.isEmpty, !category.contains(" ") else { return nil }
        let after = message[message.index(after: close)...].drop(while: { $0 == " " })
        return (category, String(after))
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return f
    }()
}

/// Reports whether a physical device is currently locked, via
/// `devicectl device info lockState` (`result.passcodeRequired`). `devicectl`
/// refuses to launch apps on a locked device, so the console source waits on this.
enum IOSDeviceLock {
    /// `true` = locked, `false` = unlocked, `nil` if the state can't be determined.
    static func isLocked(udid: String) async -> Bool? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jaca-lockstate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? await CommandRunner.run(
            AppleToolchain.xcrun,
            ["devicectl", "device", "info", "lockState", "--device", udid, "--json-output", tmp.path],
            environment: AppleToolchain.environment(),
            timeout: 8   // polled in a loop — never let a wedged devicectl stack up
        )) != nil,
            let data = try? Data(contentsOf: tmp),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let result = (root["result"] as? [String: Any]) ?? root
        return result["passcodeRequired"] as? Bool
    }
}

/// Streams a physical iOS device app's **full logs** by launching it under
/// `devicectl`'s console with `OS_ACTIVITY_DT_MODE=enable`:
/// `xcrun devicectl device process launch --console --terminate-existing
///  -e {"OS_ACTIVITY_DT_MODE":"enable"} <udid> <bundle>`.
///
/// Unlike the passive `idevicesyslog` relay (whole-device, `<private>`-redacted, no
/// stdout), this is scoped to one app and yields un-redacted `os_log` plus
/// `print()` output — the Xcode-console experience. Launching is unavoidable
/// (there's no way to tap an already-running app's stdout), so starting capture
/// (re)launches the targeted app, by design.
///
/// `devicectl` can only launch on an *unlocked* device, so the source first waits
/// for the device to be unlocked — prompting once and polling — then launches.
/// That turns the worst failure (locked → zero logs, no reason) into a clear
/// "unlock to continue" that auto-starts the moment you unlock.
final class IOSDeviceConsoleLogSource: LogSource {
    private let udid: String
    private let bundleID: String
    private let lock = NSLock()
    private var continuation: AsyncStream<LogLine>.Continuation?
    private var process: StreamingProcess?
    private var task: Task<Void, Never>?

    init(udid: String, bundleID: String) {
        self.udid = udid
        self.bundleID = bundleID
    }

    func start() throws -> AsyncStream<LogLine> {
        var cont: AsyncStream<LogLine>.Continuation!
        let out = AsyncStream<LogLine> { cont = $0 }
        lock.lock(); continuation = cont; lock.unlock()

        let t = Task { [weak self] in
            guard let self else { cont.finish(); return }
            await self.waitForUnlock()
            guard !Task.isCancelled else { cont.finish(); return }
            await self.launchAndStream(cont)
        }
        lock.lock(); task = t; lock.unlock()
        cont.onTermination = { [weak self] _ in self?.stop() }
        return out
    }

    func stop() {
        lock.lock(); let t = task; task = nil; let p = process; process = nil; lock.unlock()
        t?.cancel()
        p?.stop()
    }

    /// Blocks until the device is unlocked — devicectl can't launch while locked.
    /// Prompts once, polls every 2s; an indeterminate state (nil) means "try anyway".
    private func waitForUnlock() async {
        var prompted = false
        while !Task.isCancelled {
            guard await IOSDeviceLock.isLocked(udid: udid) == true else {
                if prompted { emitMarker("🔓 \(bundleID) — device unlocked, launching…") }
                return
            }
            if !prompted {
                emitMarker("🔒 Unlock your iPhone to stream \(bundleID)…")
                prompted = true
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func launchAndStream(_ cont: AsyncStream<LogLine>.Continuation) async {
        let proc = StreamingProcess(
            executable: AppleToolchain.xcrun,
            arguments: ["devicectl", "device", "process", "launch",
                        "--console", "--terminate-existing",
                        "--device", udid,
                        "-e", #"{"OS_ACTIVITY_DT_MODE":"enable"}"#,
                        bundleID],
            environment: AppleToolchain.environment()
        )
        lock.lock(); process = proc; lock.unlock()

        let stdoutLines: AsyncStream<String>
        do {
            // The os_log mirror lands on stderr; print() on stdout — fold both in.
            stdoutLines = try proc.start(onStderrLine: { [weak self] raw in self?.emit(raw) })
        } catch {
            cont.finish(); return
        }
        for await raw in stdoutLines { emit(raw) }
        cont.finish()
    }

    private func emit(_ raw: String) {
        guard let line = IOSDeviceConsoleParser.parse(raw) else { return }
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(line)
    }

    private func emitMarker(_ message: String) {
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(LogLine.marker(message))
    }
}
