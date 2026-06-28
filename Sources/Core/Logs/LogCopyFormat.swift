import Foundation

/// The fields a log row exposes for the configurable copy format. Both device logs (`LogLine`) and
/// Cloud Logging (`CloudLogEntry`) map into this, so one formatter serves every log list.
struct LogCopyFields: Sendable {
    var date: Date
    var level: String          // full, e.g. "Error" / "ERROR"
    var levelShort: String     // single letter, e.g. "E"
    var tag: String
    var message: String
    /// Source-specific extras referenced by `{pid}`, `{logId}`, `{trace}`, … ("" if N/A).
    var extras: [String: String] = [:]
}

/// An app-wide, configurable format for copying selected log rows (⌘C). A `template` of `{tokens}`
/// plus a `dateFormat` (a Foundation/ICU pattern the `{date}` token uses, e.g. `HH:mm:ss.SSS`,
/// `mm:ss`, `yyyy-MM-dd HH:mm:ss`). When a token resolves to empty (e.g. no tag) one adjacent
/// template space is dropped so the line stays clean; the message's own spacing is untouched.
/// Pure → unit-tested.
struct LogCopyFormat: Codable, Sendable, Hashable {
    var template: String
    var dateFormat: String

    static let `default` = LogCopyFormat(template: "{date} {level} {tag}  {message}", dateFormat: "HH:mm:ss.SSS")

    /// Tokens the template understands (shown in the modal legend).
    static let knownTokens = ["date", "level", "levelShort", "tag", "message", "pid", "logId", "trace"]

    init(template: String, dateFormat: String) {
        self.template = template
        self.dateFormat = dateFormat
    }

    enum CodingKeys: String, CodingKey { case template, dateFormat }

    /// Migration-safe decode (defaults for any missing key).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        template = try c.decodeIfPresent(String.self, forKey: .template) ?? Self.default.template
        dateFormat = try c.decodeIfPresent(String.self, forKey: .dateFormat) ?? Self.default.dateFormat
    }

    /// Renders many rows (builds the date formatter once), one per line.
    func render(_ rows: [LogCopyFields]) -> String {
        let df = Self.makeDateFormatter(dateFormat)
        return rows.map { render($0, formatter: df) }.joined(separator: "\n")
    }

    func render(_ row: LogCopyFields, formatter: DateFormatter? = nil) -> String {
        let df = formatter ?? Self.makeDateFormatter(dateFormat)
        var values: [String: String] = [
            "date": dateFormat.isEmpty ? "" : df.string(from: row.date),
            "level": row.level,
            "levelShort": row.levelShort,
            "tag": row.tag,
            "message": row.message,
        ]
        for (k, v) in row.extras where values[k] == nil { values[k] = v }
        return Self.substitute(template, values)
    }

    private static func makeDateFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// Substitutes `{token}`s. Unknown tokens stay literal. An empty known token drops a single
    /// directly-adjacent template space, so `"[{level}] {tag} {message}"` with no tag becomes
    /// `"[E] message"`, not `"[E]  message"`.
    static func substitute(_ template: String, _ values: [String: String]) -> String {
        let chars = Array(template)
        var out = ""
        out.reserveCapacity(template.count + 32)
        var i = 0
        while i < chars.count {
            guard chars[i] == "{", let close = nextIndex(of: "}", in: chars, from: i + 1) else {
                out.append(chars[i]); i += 1; continue
            }
            let name = String(chars[(i + 1)..<close])
            guard let value = values[name] else {           // unknown token → keep literal
                out.append(chars[i]); i += 1; continue
            }
            if value.isEmpty {
                if out.last == " " { out.removeLast() }                       // eat one preceding space…
                else if close + 1 < chars.count, chars[close + 1] == " " {    // …or one following space
                    i = close + 2; continue
                }
            } else {
                out += value
            }
            i = close + 1
        }
        return out
    }

    private static func nextIndex(of target: Character, in chars: [Character], from start: Int) -> Int? {
        var j = start
        while j < chars.count { if chars[j] == target { return j }; j += 1 }
        return nil
    }
}

/// A named, one-click copy-format preset shown in the config modal.
struct LogCopyFormatPreset: Identifiable, Sendable {
    let name: String
    let format: LogCopyFormat
    var id: String { name }
}

enum LogCopyPresets {
    static let all: [LogCopyFormatPreset] = [
        LogCopyFormatPreset(name: "Time · level · tag · message",
                            format: LogCopyFormat(template: "{date} {level} {tag}  {message}", dateFormat: "HH:mm:ss.SSS")),
        LogCopyFormatPreset(name: "Message only",
                            format: LogCopyFormat(template: "{message}", dateFormat: "")),
        LogCopyFormatPreset(name: "[level] message",
                            format: LogCopyFormat(template: "[{level}] {message}", dateFormat: "")),
        LogCopyFormatPreset(name: "Minutes:seconds · message",
                            format: LogCopyFormat(template: "{date}  {message}", dateFormat: "mm:ss")),
        LogCopyFormatPreset(name: "Full date · tag · message",
                            format: LogCopyFormat(template: "{date} {tag}  {message}", dateFormat: "yyyy-MM-dd HH:mm:ss")),
        LogCopyFormatPreset(name: "[level] time · tag · message",
                            format: LogCopyFormat(template: "[{level}] {date} {tag}  {message}", dateFormat: "HH:mm:ss")),
    ]

    /// A representative row used to show example output in the modal.
    static let sample = LogCopyFields(
        date: sampleDate, level: "ERROR", levelShort: "E", tag: "AuthService",
        message: "Login failed for user 42", extras: ["pid": "1234", "logId": "stdout", "trace": "a1b2c3"])

    private static let sampleDate: Date = {
        var c = DateComponents()
        c.year = 2024; c.month = 3; c.day = 15; c.hour = 14; c.minute = 23; c.second = 45; c.nanosecond = 678_000_000
        return Calendar.current.date(from: c) ?? Date(timeIntervalSince1970: 1_710_523_425)
    }()
}

// MARK: - Source mappings

extension LogLine {
    var copyFields: LogCopyFields {
        LogCopyFields(date: timestamp, level: level.name, levelShort: level.short,
                      tag: tag, message: message,
                      extras: ["pid": pid > 0 ? String(pid) : "", "process": processName ?? ""])
    }
}

extension CloudLogEntry {
    var copyFields: LogCopyFields {
        LogCopyFields(date: timestamp, level: severity.apiName, levelShort: severity.short,
                      tag: tag, message: message,
                      extras: ["logId": logId, "trace": trace ?? "", "insertId": insertId])
    }
}
