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

/// Persists the saved query + SQL templates to `~/.jaca/cloud-logging/templates.json` (global,
/// not per-project), so a new session can start from a saved template. Atomic writes.
struct CloudTemplateStore: Sendable {
    let fileURL: URL

    private struct Payload: Codable {
        var queries: [CloudQueryTemplate]
        var sql: [CloudSqlTemplate]
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
