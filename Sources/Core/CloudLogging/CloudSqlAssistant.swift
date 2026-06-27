import Foundation

/// Distinct sample values observed for one label key — so the model learns the *real* format of
/// each label (e.g. `platform = ios | android | web`), which lets it map a vague request like
/// "filter by iOS" onto the exact `labels.platform = 'ios'` clause. How many values are included
/// is controlled per key by `LabelExampleRule` (default: one).
struct CloudSqlLabelSample: Sendable, Equatable {
    /// `labels` (entry labels → `labels_json`) or `resource` (→ `resource_labels_json`).
    let scope: String
    let key: String
    let values: [String]
}

/// How many distinct values a label key has in the captured logs — drives the example-count modal
/// (so the user sees a key's cardinality before choosing 1 / N / all).
struct CloudLabelCardinality: Sendable, Equatable, Identifiable {
    let scope: String
    let key: String
    let distinctValues: Int
    var id: String { "\(scope)\t\(key)" }
}

/// The "generate a Cloud Logging SQL filter from a plain-English request" use case for the Ask
/// Claude feature: it owns the **system prompt** (table schema + conventions + live label
/// examples) and the JSON contract Claude must reply with. Pure → unit-tested.
enum CloudSqlAssistant {
    /// What Claude must return (JSON only).
    struct Suggestion: Decodable, Sendable, Equatable {
        let sql: String
        let explanation: String?
    }

    /// Enumerates every label key/value actually present (entry + resource labels), ranked by
    /// frequency within each key, for `samples(from:rules:)` to bucket into examples. The rank cap
    /// keeps a pathological high-cardinality key from returning a huge result. Read-only.
    static let labelSampleSQL = """
    WITH counts AS (
      SELECT 'labels' AS scope, je.key AS k, je.value AS v, COUNT(*) AS n
      FROM log_entry, json_each(log_entry.labels_json) je
      WHERE json_valid(log_entry.labels_json)
      GROUP BY je.key, je.value
      UNION ALL
      SELECT 'resource', je.key, je.value, COUNT(*)
      FROM log_entry, json_each(log_entry.resource_labels_json) je
      WHERE json_valid(log_entry.resource_labels_json)
      GROUP BY je.key, je.value
    )
    SELECT scope, k, v, n FROM (
      SELECT scope, k, v, n, ROW_NUMBER() OVER (PARTITION BY scope, k ORDER BY n DESC, v) AS rn FROM counts
    ) WHERE rn <= 500
    ORDER BY scope, k, n DESC, v;
    """

    /// Distinct value count per label key, for the example-count modal.
    static let labelCardinalitySQL = """
    SELECT scope, k, COUNT(*) AS distinct_values FROM (
      SELECT DISTINCT 'labels' AS scope, je.key AS k, je.value AS v
      FROM log_entry, json_each(log_entry.labels_json) je WHERE json_valid(log_entry.labels_json)
      UNION
      SELECT DISTINCT 'resource', je.key, je.value
      FROM log_entry, json_each(log_entry.resource_labels_json) je WHERE json_valid(log_entry.resource_labels_json)
    )
    GROUP BY scope, k
    ORDER BY scope, k;
    """

    /// Hard upper bound on how many values an `all` rule actually sends (keeps the prompt sane).
    static let allCap = 100

    /// Buckets the `(scope, key, value, count)` rows from `labelSampleSQL` into example values per
    /// key, honoring each key's `LabelExampleRule` (default: one value). Rows arrive count-desc, so
    /// a capped key keeps its most common values.
    static func samples(from rows: [[String?]],
                        rules: [String: LabelExampleRule] = [:],
                        defaultRule: LabelExampleRule = .default,
                        maxKeys: Int = 80) -> [CloudSqlLabelSample] {
        var order: [String] = []                         // "scope\tkey", in first-seen order
        var values: [String: [String]] = [:]
        for row in rows where row.count >= 3 {
            guard let scope = row[0], let key = row[1], let value = row[2], !value.isEmpty else { continue }
            let id = "\(scope)\t\(key)"
            if values[id] == nil { values[id] = []; order.append(id) }
            let rule = rules[key] ?? defaultRule
            let limit = rule.all ? allCap : min(rule.count, allCap)
            if values[id]!.count < limit, !values[id]!.contains(value) { values[id]!.append(value) }
        }
        return order.prefix(maxKeys).map { id in
            let parts = id.split(separator: "\t", maxSplits: 1).map(String.init)
            return CloudSqlLabelSample(scope: parts[0], key: parts.count > 1 ? parts[1] : "", values: values[id] ?? [])
        }
    }

    /// Parses the `labelCardinalitySQL` rows into `CloudLabelCardinality`.
    static func cardinalities(from rows: [[String?]]) -> [CloudLabelCardinality] {
        rows.compactMap { row in
            guard row.count >= 3, let scope = row[0], let key = row[1], let count = row[2].flatMap({ Int($0) })
            else { return nil }
            return CloudLabelCardinality(scope: scope, key: key, distinctValues: count)
        }
    }

    /// Builds the full system prompt: role + strict JSON contract + table schema + the app's
    /// query conventions + the live label examples + the user's current query as a starting point.
    static func systemPrompt(logName: String?, samples: [CloudSqlLabelSample], currentSQL: String) -> String {
        var s = """
        You generate a single read-only SQLite query for a Google Cloud Logging viewer. The user \
        describes, in plain language, which log lines they want to see; you return the SQL that \
        filters to them. The query runs over a local SQLite mirror of the captured logs (one row \
        per log entry), and its result rows are shown back in the log list.

        Respond with ONLY a JSON object, no prose and no markdown fences:
        {"sql": "<the full SQL query>", "explanation": "<one short sentence on what it does>"}

        Hard rules:
        - Read-only only: a single SELECT (or WITH … SELECT). Never INSERT/UPDATE/DELETE/PRAGMA-write.
        - ALWAYS select `insert_id` and `seq` — the viewer maps result rows back to the captured \
        log by them. Keep `ORDER BY seq DESC` and a `LIMIT` (default 1000) unless the user implies otherwise.
        - Do NOT use any tools or ask questions. Use only the schema, conventions and examples below.
        - Pretty-print the SQL so it's easy to read: UPPERCASE keywords, one major clause per line \
        (WITH / SELECT / FROM / JOIN / WHERE / GROUP BY / HAVING / ORDER BY / LIMIT), each selected \
        column and each AND/OR condition on its own indented line, and 2-space indentation. Put real \
        newlines inside the JSON string value (escaped as \\n), not a single long line.

        Table `log_entry` columns:
        """
        for c in CloudSqlSchema.columns {
            s += "\n  \(c.name) (\(c.type)) — \(c.note)"
        }

        s += """


        Conventions:
        - Labels are JSON: entry labels in `labels_json`, resource labels in `resource_labels_json`. \
        Read a label with `json_extract(labels_json, '$.<key>')` (case-sensitive key).
        - Severity: numeric `severity` (100=DEBUG 200=INFO 400=WARNING 500=ERROR 600=CRITICAL) or \
        text `severity_name`. "errors and worse" → `severity >= 500`.
        - Free-text search on the message uses `text_payload LIKE '%…%'` (case-insensitive for ASCII).
        - Timestamps: `ts` is unix epoch seconds — `datetime(ts,'unixepoch','localtime')` for display.
        - You may inject synthetic separator rows: add an `is_marker` column (`0` for real rows, \
        `1` for a divider) and put the divider text in `text_payload`; the viewer renders `is_marker=1` \
        rows as a centered divider. Only do this if the user asks for grouping/sections.
        """

        if let logName, !logName.isEmpty {
            s += "\n\nThe session is currently scoped to log: \(logName)."
        }

        if samples.isEmpty {
            s += "\n\nNo label examples are available yet (few logs captured)."
        } else {
            s += "\n\nLabels seen in the captured logs, each shown as the EXACT expression to filter on "
            s += "followed by a few real SAMPLE values. The values are ILLUSTRATIVE — they show the "
            s += "shape/format of each label, NOT a list of allowed values and NOT filters to apply. "
            s += "Copy the json_extract(...) expression verbatim, but only filter on a specific value "
            s += "if the user's request clearly refers to it (e.g. \"iOS\" → a value like `ios`). Never "
            s += "add a condition on a sample value the user didn't ask for, and never assume the listed "
            s += "values are the only possible ones."
            for sample in samples {
                let column = sample.scope == "resource" ? "resource_labels_json" : "labels_json"
                s += "\n  json_extract(\(column), '$.\(sample.key)')  →  \(sample.values.joined(separator: ", "))"
            }
        }

        s += "\n\nThe user's current query (a starting point you can refine or replace):\n\(currentSQL)"
        return s
    }

    /// Parses Claude's reply text into a `Suggestion` (tolerating fences / surrounding prose).
    static func parse(_ text: String) -> Suggestion? {
        guard let data = ClaudeJSON.extractObject(from: text) else { return nil }
        return try? JSONDecoder().decode(Suggestion.self, from: data)
    }
}
