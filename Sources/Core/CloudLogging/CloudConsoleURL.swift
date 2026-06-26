import Foundation

/// Builds and parses Google Cloud **Logs Explorer** URLs
/// (`https://console.cloud.google.com/logs/query;query=<encoded>?project=<id>`), so a session's
/// filter can be shared with a colleague (build) and a pasted Console URL can seed a new session
/// (parse). Pure → unit-tested.
enum CloudConsoleURL {
    private static let base = "https://console.cloud.google.com/logs/query"

    /// Characters left un-encoded in the `;query=` matrix value (RFC 3986 unreserved). Everything
    /// else — spaces, quotes, parens, `;`, `?`, newlines — is percent-encoded so the URL is safe.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// A shareable Logs Explorer URL for `filter` in `project`. An empty filter yields a project
    /// link with no query.
    static func build(project: String, filter: String) -> String {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectEnc = project.addingPercentEncoding(withAllowedCharacters: unreserved) ?? project
        guard !trimmed.isEmpty else { return "\(base)?project=\(projectEnc)" }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: unreserved) ?? trimmed
        return "\(base);query=\(encoded)?project=\(projectEnc)"
    }

    /// Extracts `(project, query)` from a pasted Logs Explorer URL. Either may be nil. The filter
    /// is returned percent-decoded (the raw Cloud Logging filter string).
    static func parse(_ urlString: String) -> (project: String?, query: String?) {
        let parts = urlString.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let pathPart = String(parts.first ?? "")
        let queryPart = parts.count > 1 ? String(parts[1]) : ""

        var project: String?
        var query: String?
        for kv in queryPart.split(separator: "&") {
            let pair = kv.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let value = String(pair[1]).removingPercentEncoding
            switch pair[0] {
            case "project": project = value
            case "query": if query == nil { query = value }   // some variants use a normal param
            default: break
            }
        }
        // Matrix form: …/logs/query;query=ENC;otherParam=…
        if let r = pathPart.range(of: "query=") {
            let after = pathPart[r.upperBound...]
            let raw = after.prefix { $0 != ";" }
            if let decoded = String(raw).removingPercentEncoding, !decoded.isEmpty { query = decoded }
        }
        return (project?.isEmpty == true ? nil : project,
                query?.isEmpty == true ? nil : query)
    }

    /// Whether the string looks like a Logs Explorer URL we can ingest.
    static func looksLikeConsoleURL(_ s: String) -> Bool {
        s.contains("console.cloud.google.com/logs")
    }
}
