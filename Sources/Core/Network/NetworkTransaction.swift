import Foundation

struct HeaderPair: Sendable, Hashable, Identifiable {
    let name: String
    let value: String
    var id: String { name + ":" + value }
}

/// A single captured HTTP(S) request/response, with timing and sizes — the unit
/// shown in the network inspector list and detail panes.
struct NetworkTransaction: Identifiable, Sendable, Hashable {
    let id: UUID
    var method: String
    var url: String
    var host: String
    var scheme: String

    var requestHeaders: [HeaderPair]
    var requestBody: Data?

    var statusCode: Int?
    var responseHeaders: [HeaderPair]
    var responseBody: Data?
    var responseContentType: String?

    var startedAt: Date
    var responseReceivedAt: Date?   // time to first byte
    var finishedAt: Date?

    var requestBytes: Int
    var responseBytes: Int
    var error: String?

    /// Initiating call stack — only the in-process agent can provide this; nil for proxy capture.
    var callStack: [String]? = nil

    init(id: UUID = UUID(), method: String, url: String, host: String, scheme: String,
         requestHeaders: [HeaderPair] = [], requestBody: Data? = nil, startedAt: Date = Date()) {
        self.id = id
        self.method = method
        self.url = url
        self.host = host
        self.scheme = scheme
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.statusCode = nil
        self.responseHeaders = []
        self.responseBody = nil
        self.responseContentType = nil
        self.startedAt = startedAt
        self.responseReceivedAt = nil
        self.finishedAt = nil
        self.requestBytes = requestBody?.count ?? 0
        self.responseBytes = 0
        self.error = nil
    }

    /// Total wall-clock duration once finished, in seconds.
    var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    /// Time-to-first-byte in seconds.
    var ttfb: TimeInterval? {
        guard let responseReceivedAt else { return nil }
        return responseReceivedAt.timeIntervalSince(startedAt)
    }

    var path: String {
        URLComponents(string: url)?.path.isEmpty == false
            ? URLComponents(string: url)!.path
            : (url.hasPrefix(scheme) ? url : "/")
    }

    var isInFlight: Bool { finishedAt == nil && error == nil }

    var statusText: String {
        if let error { return "ERR" }
        guard let statusCode else { return "…" }
        return "\(statusCode)"
    }
}
