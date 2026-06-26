import Foundation

/// A single parsed Cloud Logging entry. `seq` is a monotonic id stamped by the session
/// (stable for list diffing, like `LogLine.seq`); `raw` keeps the full pretty-printed JSON
/// for the detail panel. `message` is the rendered payload (textPayload, else pretty
/// json/proto payload). All fields are value types so the entry is `Sendable` and can flow
/// from the background poller to the main actor.
struct CloudLogEntry: Identifiable, Sendable, Hashable {
    var seq: UInt64 = 0
    let insertId: String
    let timestamp: Date
    let receiveTimestamp: Date?
    let severity: CloudSeverity
    /// Full log name: `projects/<id>/logs/<encoded>`.
    let logName: String
    /// Decoded, human-readable log id (`stdout`, `run.googleapis.com/requests`, …).
    let logId: String
    /// The text shown in the list: `textPayload`, else pretty-printed `jsonPayload`/`protoPayload`.
    let message: String
    let payloadKind: PayloadKind
    let labels: [String: String]
    let resourceType: String
    let resourceLabels: [String: String]
    let trace: String?
    let spanId: String?
    /// One-line summary of `httpRequest` if present (`GET /foo → 200 · 12ms`).
    let httpRequestSummary: String?
    /// Full entry as pretty JSON, for the detail panel's raw view.
    let raw: String

    var id: UInt64 { seq }

    /// The list's "tag" column: the `labels.tag` value when present (a per-log human tag),
    /// otherwise empty — the log name is the same for every row, so it's useless there.
    var tag: String { labels["tag"] ?? "" }

    enum PayloadKind: String, Sendable, Hashable { case text, json, proto, none }
}

/// Decodes the JSON array printed by `gcloud logging read --format=json` into
/// `CloudLogEntry` values. Pure (operates on `Data`/dictionaries) → unit-tested.
enum CloudLogEntryDecoder {
    static func decodeArray(_ data: Data) -> [CloudLogEntry] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr.map { decode($0) }
    }

    static func decode(_ obj: [String: Any]) -> CloudLogEntry {
        let insertId = obj["insertId"] as? String ?? ""
        let timestamp = (obj["timestamp"] as? String).flatMap(CloudTimestamp.parse) ?? Date()
        let receiveTimestamp = (obj["receiveTimestamp"] as? String).flatMap(CloudTimestamp.parse)
        let severity = CloudSeverity(apiValue: obj["severity"] as? String)
        let logName = obj["logName"] as? String ?? ""

        let (message, kind) = renderPayload(obj)
        let labels = (obj["labels"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]

        let resource = obj["resource"] as? [String: Any]
        let resourceType = resource?["type"] as? String ?? ""
        let resourceLabels = (resource?["labels"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]

        return CloudLogEntry(
            insertId: insertId,
            timestamp: timestamp,
            receiveTimestamp: receiveTimestamp,
            severity: severity,
            logName: logName,
            logId: CloudLogName.shortId(logName),
            message: message,
            payloadKind: kind,
            labels: labels,
            resourceType: resourceType,
            resourceLabels: resourceLabels,
            trace: (obj["trace"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            spanId: (obj["spanId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            httpRequestSummary: httpSummary(obj["httpRequest"] as? [String: Any]),
            raw: prettyJSON(obj) ?? ""
        )
    }

    /// Picks the entry's payload (text wins, then json, then proto) and renders it to a
    /// display string.
    private static func renderPayload(_ obj: [String: Any]) -> (String, CloudLogEntry.PayloadKind) {
        if let text = obj["textPayload"] as? String { return (text, .text) }
        if let json = obj["jsonPayload"] as? [String: Any] { return (prettyJSON(json) ?? "{}", .json) }
        if let proto = obj["protoPayload"] as? [String: Any] { return (prettyJSON(proto) ?? "{}", .proto) }
        return ("", .none)
    }

    private static func httpSummary(_ http: [String: Any]?) -> String? {
        guard let http else { return nil }
        let method = http["requestMethod"] as? String ?? ""
        let url = http["requestUrl"] as? String ?? ""
        let status = (http["status"] as? Int).map(String.init) ?? ""
        let latency = http["latency"] as? String ?? ""
        var parts: [String] = []
        if !method.isEmpty || !url.isEmpty { parts.append("\(method) \(url)".trimmingCharacters(in: .whitespaces)) }
        if !status.isEmpty { parts.append("→ \(status)") }
        if !latency.isEmpty { parts.append("· \(latency)") }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private static func prettyJSON(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
