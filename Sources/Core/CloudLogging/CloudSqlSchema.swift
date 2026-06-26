import Foundation

/// The fixed schema of the per-session SQLite (`log_entry`). Drives the SQL editor's schema
/// reference, autocomplete, and syntax highlighting — since the table is known exactly.
enum CloudSqlSchema {
    struct Column: Hashable { let name: String; let type: String; let note: String }

    static let table = "log_entry"

    static let columns: [Column] = [
        Column(name: "insert_id", type: "TEXT", note: "Cloud Logging insertId (unique) — KEEP in SELECT so matching rows show in the list"),
        Column(name: "seq", type: "INTEGER", note: "Monotonic id — handy for ORDER BY (insert_id is the stable key to KEEP)"),
        Column(name: "ts", type: "REAL", note: "Unix epoch seconds — datetime(ts,'unixepoch','localtime')"),
        Column(name: "severity", type: "INTEGER", note: "100=DEBUG 200=INFO 400=WARNING 500=ERROR 600=CRITICAL"),
        Column(name: "severity_name", type: "TEXT", note: "ERROR / WARNING / INFO / …"),
        Column(name: "text_payload", type: "TEXT", note: "The log message (rendered for json/proto payloads)"),
        Column(name: "log_id", type: "TEXT", note: "Short log name"),
        Column(name: "log_name", type: "TEXT", note: "Full projects/<id>/logs/<encoded>"),
        Column(name: "labels_json", type: "TEXT", note: "Entry labels as JSON — json_extract(labels_json,'$.key')"),
        Column(name: "resource_type", type: "TEXT", note: "e.g. cloud_run_revision"),
        Column(name: "resource_labels_json", type: "TEXT", note: "Resource labels JSON — json_extract(resource_labels_json,'$.key')"),
        Column(name: "trace", type: "TEXT", note: "Trace id"),
        Column(name: "span_id", type: "TEXT", note: "Span id"),
        Column(name: "receive_ts", type: "REAL", note: "When Logging received it (unix epoch)"),
        Column(name: "payload_kind", type: "TEXT", note: "text / json / proto / none"),
        Column(name: "raw", type: "TEXT", note: "Full entry JSON"),
    ]

    static let columnNames: [String] = columns.map(\.name)

    /// SQL keywords + functions, for highlighting and autocomplete.
    static let keywords: [String] = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "NULL", "IS", "IN", "LIKE", "GLOB",
        "BETWEEN", "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "ASC", "DESC",
        "DISTINCT", "AS", "ON", "JOIN", "LEFT", "INNER", "OUTER", "UNION", "ALL", "WITH",
        "CASE", "WHEN", "THEN", "ELSE", "END",
        "COUNT", "SUM", "AVG", "MIN", "MAX", "CAST", "COALESCE", "OVER", "PARTITION",
        "datetime", "date", "strftime", "json_extract", "substr", "length", "lower", "upper",
    ]

    /// Upper-cased keyword set, for fast highlighting lookups.
    static let keywordSet: Set<String> = Set(keywords.map { $0.uppercased() })

    /// A WHERE clause matching an entry label by key (value left blank for the user to fill).
    static func labelFilter(key: String) -> String {
        "json_extract(labels_json, '$.\(key)') = ''"
    }
}
