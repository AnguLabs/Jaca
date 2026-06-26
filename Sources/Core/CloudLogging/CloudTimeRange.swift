import Foundation

/// The time window for a session's logs (req 8): a relative "last N" (which streams live,
/// polling forward) or an absolute start/end (a one-shot fetch). Pure → unit-tested.
enum CloudTimeRange: Codable, Sendable, Hashable {
    case last(minutes: Int)
    case between(start: Date, end: Date)

    /// Quick-pick relative presets surfaced in the toolbar.
    static let presets: [(label: String, minutes: Int)] = [
        ("Last 5m", 5),
        ("Last 15m", 15),
        ("Last 1h", 60),
        ("Last 6h", 360),
        ("Last 24h", 1_440),
        ("Last 7d", 10_080),
    ]

    /// Relative ranges stream live (poll forward); absolute ranges are a finite fetch.
    var isLive: Bool {
        if case .last = self { return true }
        return false
    }

    /// The start instant of the window, given "now".
    func start(now: Date) -> Date {
        switch self {
        case .last(let minutes): return now.addingTimeInterval(-Double(minutes) * 60)
        case .between(let start, _): return start
        }
    }

    /// The `timestamp` filter clause for the initial backfill / one-shot query.
    func clause(now: Date) -> String {
        switch self {
        case .last(let minutes):
            let start = now.addingTimeInterval(-Double(minutes) * 60)
            return "timestamp>=\(CloudTimestamp.quote(start))"
        case .between(let start, let end):
            return "timestamp>=\(CloudTimestamp.quote(start)) AND timestamp<=\(CloudTimestamp.quote(end))"
        }
    }

    var label: String {
        switch self {
        case .last(let minutes):
            if let preset = Self.presets.first(where: { $0.minutes == minutes }) { return preset.label }
            if minutes % 1_440 == 0 { return "Last \(minutes / 1_440)d" }
            if minutes % 60 == 0 { return "Last \(minutes / 60)h" }
            return "Last \(minutes)m"
        case .between:
            return "Custom range"
        }
    }
}
