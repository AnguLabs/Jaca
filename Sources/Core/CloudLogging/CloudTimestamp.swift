import Foundation

/// Parsing/formatting for Cloud Logging RFC3339 timestamps. The API emits up to
/// nanosecond precision (`.fffffffffZ`), which `ISO8601DateFormatter` can't parse, so
/// we normalize the fractional part to milliseconds first. Pure → unit-tested.
enum CloudTimestamp {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String) -> Date? {
        let normalized = normalizeFraction(s)
        return withFraction.date(from: normalized) ?? plain.date(from: normalized)
    }

    /// RFC3339 string (millisecond precision, `Z`) for use in filter clauses.
    static func format(_ date: Date) -> String { withFraction.string(from: date) }

    /// Quoted RFC3339 string for embedding directly in a Logging filter
    /// (`timestamp>="2024-…Z"`).
    static func quote(_ date: Date) -> String { "\"" + format(date) + "\"" }

    /// Truncates/pads the fractional seconds of an RFC3339 string to exactly 3 digits
    /// (`.fffZ` / `.fff+00:00`) so the millisecond ISO8601 parser accepts it. Strings with
    /// no fractional part are returned unchanged.
    static func normalizeFraction(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return s }
        let afterDot = s[s.index(after: dot)...]
        let digits = afterDot.prefix { $0.isNumber }
        let suffix = afterDot.drop { $0.isNumber }   // "Z" or "+00:00"
        var frac = String(digits.prefix(3))
        while frac.count < 3 { frac += "0" }
        return String(s[..<dot]) + "." + frac + String(suffix)
    }
}
