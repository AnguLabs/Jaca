import Foundation

/// How a string field is matched, mapped to the Cloud Logging filter language. This is the
/// "simple, not query-language driven" surface the user picks from (req 9).
enum CloudMatchMode: String, Codable, Sendable, CaseIterable, Hashable {
    case contains       // case-insensitive substring  → field:"v"
    case exact          // exact equality              → field="v"
    case regex          // RE2 regex                   → field=~"v"
    case notContains    // negated substring           → NOT field:"v"

    var label: String {
        switch self {
        case .contains: return "contains"
        case .exact: return "is exactly"
        case .regex: return "matches regex"
        case .notContains: return "doesn't contain"
        }
    }

    /// Builds one filter term for `field` (already a valid filter LHS like `textPayload`
    /// or `labels.foo`) and `value` (raw user text).
    func term(field: String, value: String) -> String {
        let v = CloudFilter.quote(value)
        switch self {
        case .contains: return "\(field):\(v)"
        case .exact: return "\(field)=\(v)"
        case .regex: return "\(field)=~\(v)"
        case .notContains: return "NOT \(field):\(v)"
        }
    }
}

/// A single `textPayload` condition.
struct TextCondition: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var mode: CloudMatchMode = .contains
    var value: String = ""
}

/// Which label namespace a condition targets.
enum LabelScope: String, Codable, Sendable, Hashable {
    case entry      // labels.<key>
    case resource   // resource.labels.<key>

    func field(for key: String) -> String {
        let lhs = self == .entry ? "labels" : "resource.labels"
        return "\(lhs).\(CloudFilter.quoteKeyIfNeeded(key))"
    }
}

/// A single label condition. `key` comes from the auto-detected list.
struct LabelCondition: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var key: String = ""
    var scope: LabelScope = .entry
    var mode: CloudMatchMode = .exact
    var value: String = ""
}

/// The structured, point-and-click query for one session (req 9). Pure value type; the
/// `clauses()` it produces are AND-ed with the logName + time clauses by `CloudFilter`.
struct CloudLogQuery: Codable, Sendable, Hashable {
    /// textPayload conditions (req 9.1).
    var textConditions: [TextCondition] = []
    /// Combine multiple textPayload conditions with OR (true) or AND (false).
    var textCombineOr: Bool = true

    /// Min-severity ladder (req 9.2). `nil`/`.default` means "no severity floor".
    var minSeverity: CloudSeverity?
    /// Exact severity set; when non-empty it replaces `minSeverity`.
    var severitySet: [CloudSeverity] = []

    /// Label conditions (req 9.3).
    var labelConditions: [LabelCondition] = []
    /// Combine multiple label conditions with OR (true) or AND (false).
    var labelCombineOr: Bool = false

    var isEmpty: Bool {
        textConditions.allSatisfy { $0.value.isEmpty }
            && (minSeverity == nil || minSeverity == CloudSeverity.default)
            && severitySet.isEmpty
            && labelConditions.allSatisfy { $0.key.isEmpty || $0.value.isEmpty }
    }

    /// The list of top-level filter clauses this query contributes (each already grouped).
    func clauses() -> [String] {
        var out: [String] = []

        let textTerms = textConditions
            .filter { !$0.value.isEmpty }
            .map { $0.mode.term(field: "textPayload", value: $0.value) }
        if let group = CloudFilter.group(textTerms, or: textCombineOr) { out.append(group) }

        if !severitySet.isEmpty {
            let names = severitySet.map(\.apiName).joined(separator: " OR ")
            out.append(severitySet.count == 1 ? "severity=\(severitySet[0].apiName)" : "severity=(\(names))")
        } else if let min = minSeverity, min != .default {
            out.append("severity>=\(min.apiName)")
        }

        let labelTerms = labelConditions
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
            .map { $0.mode.term(field: $0.scope.field(for: $0.key), value: $0.value) }
        if let group = CloudFilter.group(labelTerms, or: labelCombineOr) { out.append(group) }

        return out
    }
}

/// Assembles the final Cloud Logging filter string from a logName, a time clause, and a
/// structured query — and owns the value/key quoting rules. Pure → unit-tested.
enum CloudFilter {
    /// AND of: logName clause + time clause + the query's grouped clauses. Any may be empty.
    /// When `rawFilter` is provided (a session ingested from a Cloud Console URL), it is the
    /// authoritative user portion (incl. its own logName/severity/etc.) and is used verbatim —
    /// only the time clause is ANDed on top (so live tailing still works).
    static func build(logName: String?, time: String?, query: CloudLogQuery, rawFilter: String? = nil) -> String {
        var clauses: [String] = []
        if let rawFilter, !rawFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clauses.append("(\(rawFilter))")
            if let time, !time.isEmpty { clauses.append(time) }
            return clauses.joined(separator: " AND ")
        }
        if let logName, !logName.isEmpty { clauses.append("logName=\(quote(logName))") }
        if let time, !time.isEmpty { clauses.append(time) }
        clauses.append(contentsOf: query.clauses())
        return clauses.joined(separator: " AND ")
    }

    /// Joins terms with OR/AND, wrapping in parentheses only when more than one.
    static func group(_ terms: [String], or: Bool) -> String? {
        guard !terms.isEmpty else { return nil }
        if terms.count == 1 { return terms[0] }
        return "(" + terms.joined(separator: or ? " OR " : " AND ") + ")"
    }

    /// Double-quotes a value for the filter language, escaping `\` and `"`.
    static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Quotes a label key only when it contains characters that aren't a bare identifier
    /// (e.g. `labels."run.googleapis.com/trace_id"`).
    static func quoteKeyIfNeeded(_ key: String) -> String {
        let isIdentifier = !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        return isIdentifier ? key : quote(key)
    }
}

/// Helpers for the `logName` field (which percent-encodes the log id).
enum CloudLogName {
    /// Full `projects/<id>/logs/<encoded>` name from a project id + a log id (or an
    /// already-full name, returned unchanged).
    static func full(projectID: String, logName: String) -> String {
        if logName.hasPrefix("projects/") { return logName }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = logName.addingPercentEncoding(withAllowedCharacters: allowed) ?? logName
        return "projects/\(projectID)/logs/\(encoded)"
    }

    /// The human, percent-decoded log id from a full name.
    static func shortId(_ full: String) -> String {
        guard let range = full.range(of: "/logs/") else { return full }
        let id = String(full[range.upperBound...])
        return id.removingPercentEncoding ?? id
    }
}

// MARK: - Migration-safe decoding (missing keys fall back to defaults, so adding a field never
// invalidates a persisted query in templates.json or the saved open-tabs state).

extension TextCondition {
    enum CodingKeys: String, CodingKey { case id, mode, value }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        mode = try c.decodeIfPresent(CloudMatchMode.self, forKey: .mode) ?? .contains
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }
}

extension LabelCondition {
    enum CodingKeys: String, CodingKey { case id, key, scope, mode, value }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        scope = try c.decodeIfPresent(LabelScope.self, forKey: .scope) ?? .entry
        mode = try c.decodeIfPresent(CloudMatchMode.self, forKey: .mode) ?? .exact
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }
}

extension CloudLogQuery {
    enum CodingKeys: String, CodingKey {
        case textConditions, textCombineOr, minSeverity, severitySet, labelConditions, labelCombineOr
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        textConditions = try c.decodeIfPresent([TextCondition].self, forKey: .textConditions) ?? []
        textCombineOr = try c.decodeIfPresent(Bool.self, forKey: .textCombineOr) ?? true
        minSeverity = try c.decodeIfPresent(CloudSeverity.self, forKey: .minSeverity)
        severitySet = try c.decodeIfPresent([CloudSeverity].self, forKey: .severitySet) ?? []
        labelConditions = try c.decodeIfPresent([LabelCondition].self, forKey: .labelConditions) ?? []
        labelCombineOr = try c.decodeIfPresent(Bool.self, forKey: .labelCombineOr) ?? false
    }
}
