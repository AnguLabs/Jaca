import Foundation

/// Builds the clipboard text for one or more selected log lines.
enum LogClipboard {
    /// `messagesOnly` → a level prefix + the message (e.g. `[I] hello`), one per
    /// line; otherwise prefix each with time, level and tag.
    static func text(for lines: [LogLine], messagesOnly: Bool) -> String {
        lines.map { line in
            if messagesOnly { return "[\(line.level.short)] \(line.message)" }
            let tag = line.pid > 0 ? "\(line.tag) (\(line.pid))" : line.tag
            return "\(line.timestamp.logClock) \(line.level.short) \(tag)  \(line.message)"
        }
        .joined(separator: "\n")
    }
}
