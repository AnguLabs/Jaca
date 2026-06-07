import Foundation

/// Parses `adb logcat -v threadtime` lines into `LogLine`s.
///
/// threadtime format: `MM-DD HH:MM:SS.mmm  PID  TID LEVEL TAG: message`
/// e.g. `06-07 12:34:56.789  1234  1250 I ActivityManager: Start proc`
enum LogcatParser {
    // date(1) time(2) pid(3) tid(4) level(5) tag(6, non-greedy to ": ") message(7)
    private static let regex = try! NSRegularExpression(
        pattern: #"^(\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2}\.\d{3})\s+(\d+)\s+(\d+)\s+([VDIWEFAS])\s+(.*?):\s?(.*)$"#
    )

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Parses one threadtime line. Returns nil for non-entries (e.g. the
    /// `--------- beginning of main` separators); callers can fall back to `raw`.
    /// `seq` is left at 0 — the `LogSource` assigns the real sequence id.
    static func parse(_ raw: String, year: Int? = nil) -> LogLine? {
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range) else { return nil }

        func group(_ i: Int) -> String {
            guard let r = Range(match.range(at: i), in: raw) else { return "" }
            return String(raw[r])
        }

        guard let level = LogLevel(threadtimeChar: Character(group(5))) else { return nil }
        let pid = Int32(group(3)) ?? 0
        let tid = Int32(group(4)) ?? 0
        let tag = group(6).trimmingCharacters(in: .whitespaces)
        let message = group(7)

        let resolvedYear = year ?? Calendar.current.component(.year, from: Date())
        let timestamp = formatter.date(from: "\(resolvedYear)-\(group(1)) \(group(2))") ?? Date()

        return LogLine(
            seq: 0,
            timestamp: timestamp,
            level: level,
            tag: tag,
            pid: pid,
            tid: tid,
            message: message,
            raw: raw,
            processName: nil
        )
    }

    /// Wraps a line that isn't a standard entry so nothing is silently dropped
    /// (logcat separators, daemon notices, stderr forwarded by the source).
    static func fallback(_ raw: String, level: LogLevel = .verbose) -> LogLine {
        LogLine(
            seq: 0,
            timestamp: Date(),
            level: level,
            tag: "",
            pid: 0,
            tid: 0,
            message: raw,
            raw: raw,
            processName: nil
        )
    }
}
