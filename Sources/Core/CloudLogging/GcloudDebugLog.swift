import Foundation

/// One recorded `gcloud` CLI invocation, for the debug console.
struct GcloudDebugEntry: Sendable, Identifiable {
    let id = UUID()
    let date: Date
    /// Copy-pasteable command line (shell-quoted).
    let command: String
    let exitCode: Int32
    let stderr: String
    let stdoutPreview: String
    let durationMs: Int

    var ok: Bool { exitCode == 0 }
}

/// A shared, thread-safe ring of recent `gcloud` invocations (command + exit code + stderr +
/// stdout preview), so the debug console can show exactly what Jaca ran and why a query failed.
/// Recording happens off the main actor (inside `CommandRunner`'s queue), so this is lock-guarded
/// and the UI reads `snapshot()`. Capped so it never grows unbounded.
final class GcloudDebugLog: @unchecked Sendable {
    static let shared = GcloudDebugLog()

    private let lock = NSLock()
    private var entries: [GcloudDebugEntry] = []
    private let cap = 300

    func record(command: String, exitCode: Int32, stderr: String, stdout: String, durationMs: Int) {
        let entry = GcloudDebugEntry(
            date: Date(),
            command: command,
            exitCode: exitCode,
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
            stdoutPreview: String(stdout.prefix(8_000)),
            durationMs: durationMs
        )
        lock.lock()
        entries.append(entry)
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
        lock.unlock()
    }

    /// Most recent first.
    func snapshot() -> [GcloudDebugEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries.reversed()
    }

    func clear() { lock.lock(); entries.removeAll(); lock.unlock() }

    /// Builds a copy-pasteable command string from a binary + args, shell-quoting as needed.
    static func command(_ binary: URL, _ args: [String]) -> String {
        ([binary.lastPathComponent] + args).map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = s.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:".contains($0) }
        return safe ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
