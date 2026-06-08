import Foundation

/// Severity of a log entry, ordered so `>=` works for "min level" filtering.
enum LogLevel: Int, Comparable, Sendable, Codable, CaseIterable {
    case verbose = 0
    case debug
    case info
    case warn
    case error
    case fatal

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Android threadtime single-character level (`V D I W E F`, `A`→fatal).
    init?(threadtimeChar c: Character) {
        switch c {
        case "V": self = .verbose
        case "D": self = .debug
        case "I": self = .info
        case "W": self = .warn
        case "E": self = .error
        case "F", "A": self = .fatal
        default: return nil
        }
    }

    var short: String {
        switch self {
        case .verbose: return "V"
        case .debug: return "D"
        case .info: return "I"
        case .warn: return "W"
        case .error: return "E"
        case .fatal: return "F"
        }
    }

    var name: String {
        switch self {
        case .verbose: return "Verbose"
        case .debug: return "Debug"
        case .info: return "Info"
        case .warn: return "Warn"
        case .error: return "Error"
        case .fatal: return "Fatal"
        }
    }
}

/// A single parsed log entry. `seq` is a monotonic id assigned by the `LogSource`
/// (stable for list diffing); `raw` preserves the original line for export.
struct LogLine: Identifiable, Sendable, Hashable {
    var seq: UInt64
    let timestamp: Date
    let level: LogLevel
    let tag: String
    let pid: Int32
    let tid: Int32
    let message: String
    let raw: String
    var processName: String?
    /// Synthetic line injected by Jaca (app died/restarted, stream reconnect) —
    /// rendered distinctively and never hidden by filters.
    var isMarker: Bool = false

    var id: UInt64 { seq }

    /// A synthetic marker line (seq is stamped by the session's monotonic counter).
    static func marker(_ message: String) -> LogLine {
        LogLine(seq: 0, timestamp: Date(), level: .info, tag: "", pid: -1, tid: 0,
                message: message, raw: message, processName: nil, isMarker: true)
    }
}
