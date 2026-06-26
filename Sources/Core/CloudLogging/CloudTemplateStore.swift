import Foundation

/// A saved Cloud Logging query template — just the structured query (or a raw filter), reusable
/// across sessions. No project/time config, per the request: "just the query language output".
struct CloudQueryTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var query: CloudLogQuery
    var rawFilter: String?
}

/// A saved SQL filter template.
struct CloudSqlTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var sql: String
}

// Migration-safe decoding: missing keys fall back to defaults so adding a field never drops
// saved templates.

extension CloudQueryTemplate {
    enum CodingKeys: String, CodingKey { case id, name, query, rawFilter }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        query = try c.decodeIfPresent(CloudLogQuery.self, forKey: .query) ?? CloudLogQuery()
        rawFilter = try c.decodeIfPresent(String.self, forKey: .rawFilter)
    }
}

extension CloudSqlTemplate {
    enum CodingKeys: String, CodingKey { case id, name, sql }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        sql = try c.decodeIfPresent(String.self, forKey: .sql) ?? ""
    }
}

/// Persists the saved query + SQL templates to `~/.jaca/cloud-logging/templates.json` (global,
/// not per-project), so a new session can start from a saved template. Atomic writes.
struct CloudTemplateStore: Sendable {
    let fileURL: URL

    private struct Payload: Codable {
        var queries: [CloudQueryTemplate]
        var sql: [CloudSqlTemplate]

        init(queries: [CloudQueryTemplate], sql: [CloudSqlTemplate]) {
            self.queries = queries
            self.sql = sql
        }
        enum CodingKeys: String, CodingKey { case queries, sql }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            queries = try c.decodeIfPresent([CloudQueryTemplate].self, forKey: .queries) ?? []
            sql = try c.decodeIfPresent([CloudSqlTemplate].self, forKey: .sql) ?? []
        }
    }

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".jaca", isDirectory: true)
                .appendingPathComponent("cloud-logging", isDirectory: true)
                .appendingPathComponent("templates.json")
        }
    }

    func load() -> (queries: [CloudQueryTemplate], sql: [CloudSqlTemplate]) {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return ([], []) }
        return (payload.queries, payload.sql)
    }

    func save(queries: [CloudQueryTemplate], sql: [CloudSqlTemplate]) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Payload(queries: queries, sql: sql)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
