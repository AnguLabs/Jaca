import Foundation

/// Parses one raw stdout/stderr line from `simctl launch --console-pty` into a
/// `LogLine`, or `nil` when the line is something the unified-log stream
/// (`SimulatorLogSource`) already delivers with richer metadata.
///
/// `--console-pty` taps the launched app's stdout + stderr, so it's the *only*
/// way to see `print()` / `println` output — that goes to the process's stdout
/// and never reaches OSLog. The catch: the simulator also echoes `NSLog` /
/// `os_log` to stderr, and those are already in the ndjson `log stream`. We drop
/// those mirrored lines (recognizable by their `timestamp ProcessName[pid:tid]`
/// prefix) so a merged session shows each entry once, keeping only the genuine
/// stdout/print delta.
enum SimulatorConsoleParser {
    /// Matches the simulator's NSLog/os_log stderr mirror:
    /// `2026-06-14 19:53:58.395 Teya Dev[65991:17811277] message`
    /// (ISO-ish timestamp + `ProcessName[pid:tid]`) — already in `log stream`.
    private static let mirrorPrefix = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ .+\[\d+:[0-9a-fx]+\] "#,
        options: [.caseInsensitive]
    )

    static func parse(_ raw: String, isStderr: Bool = false) -> LogLine? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard !trimmed.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        if mirrorPrefix.firstMatch(in: trimmed, range: range) != nil { return nil }

        return LogLine(
            seq: 0,
            timestamp: Date(),
            level: .info,
            tag: isStderr ? "stderr" : "stdout",
            pid: 0,
            tid: 0,
            message: trimmed,
            raw: raw,
            processName: nil,
            isConsoleOutput: true
        )
    }
}

/// Streams a simulator app's **stdout + stderr** by launching it under a PTY:
/// `xcrun simctl launch --console-pty --terminate-running-process <udid> <bundle>`.
/// Complements `SimulatorLogSource` (OSLog/ndjson) by adding `print()`/`println`
/// output. Launching is unavoidable — there's no way to attach to an already-running
/// app's stdout — so starting capture (re)launches the targeted app, by design.
final class SimulatorConsoleLogSource: LogSource {
    private let udid: String
    private let bundleID: String
    private let process: StreamingProcess
    private let lock = NSLock()
    private var continuation: AsyncStream<LogLine>.Continuation?

    init(udid: String, bundleID: String) {
        self.udid = udid
        self.bundleID = bundleID
        self.process = StreamingProcess(
            executable: AppleToolchain.xcrun,
            arguments: ["simctl", "launch", "--console-pty",
                        "--terminate-running-process", udid, bundleID],
            environment: AppleToolchain.environment()
        )
    }

    func start() throws -> AsyncStream<LogLine> {
        // Build the output stream and capture its continuation *before* starting the
        // process, so early stderr lines (objc/runtime warnings at launch) aren't lost.
        var cont: AsyncStream<LogLine>.Continuation!
        let out = AsyncStream<LogLine> { cont = $0 }
        lock.lock(); continuation = cont; lock.unlock()

        let stdoutLines: AsyncStream<String>
        do {
            // App output lands on both fds (Apple: "Log output is often directed to
            // stderr"), so fold stderr into the same parsed stream.
            stdoutLines = try process.start(onStderrLine: { [weak self] raw in
                self?.emit(raw, isStderr: true)
            })
        } catch {
            cont.finish()
            throw error
        }

        let task = Task { [weak self] in
            for await raw in stdoutLines { self?.emit(raw, isStderr: false) }
            cont.finish()
        }
        cont.onTermination = { [process] _ in
            task.cancel()
            process.stop()
        }
        return out
    }

    func stop() { process.stop() }

    private func emit(_ raw: String, isStderr: Bool) {
        guard let line = SimulatorConsoleParser.parse(raw, isStderr: isStderr) else { return }
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(line)
    }
}
