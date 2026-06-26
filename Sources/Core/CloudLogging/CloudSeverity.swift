import Foundation

/// Google Cloud Logging severity, ordered so `>=` works for "min severity" filtering.
/// Raw values mirror the API's `LogSeverity` numeric scale (DEBUG=100 … EMERGENCY=800),
/// so a higher value is genuinely more severe.
enum CloudSeverity: Int, Comparable, Sendable, Codable, CaseIterable {
    case `default` = 0
    case debug = 100
    case info = 200
    case notice = 300
    case warning = 400
    case error = 500
    case critical = 600
    case alert = 700
    case emergency = 800

    static func < (lhs: CloudSeverity, rhs: CloudSeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Parses the string form used by the Logging API (`"ERROR"`, `"WARNING"`, …).
    /// Missing/unknown maps to `.default` (the API's "no severity" bucket).
    init(apiValue: String?) {
        switch (apiValue ?? "").uppercased() {
        case "DEBUG": self = .debug
        case "INFO": self = .info
        case "NOTICE": self = .notice
        case "WARNING": self = .warning
        case "ERROR": self = .error
        case "CRITICAL": self = .critical
        case "ALERT": self = .alert
        case "EMERGENCY": self = .emergency
        default: self = .default
        }
    }

    /// Canonical API name, used when building filters (`severity >= ERROR`).
    var apiName: String {
        switch self {
        case .default: return "DEFAULT"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        case .critical: return "CRITICAL"
        case .alert: return "ALERT"
        case .emergency: return "EMERGENCY"
        }
    }

    /// Single-glyph badge for the dense log list.
    var short: String {
        switch self {
        case .default: return "·"
        case .debug: return "D"
        case .info: return "I"
        case .notice: return "N"
        case .warning: return "W"
        case .error: return "E"
        case .critical: return "C"
        case .alert: return "A"
        case .emergency: return "!"
        }
    }

    var name: String { apiName.prefix(1) + apiName.dropFirst().lowercased() }

    /// The severities surfaced as filter chips / the min-severity ladder (the rare
    /// DEFAULT/NOTICE/ALERT/EMERGENCY are still parsed, just not offered as quick picks).
    static let commonLadder: [CloudSeverity] = [.debug, .info, .warning, .error, .critical]
}
