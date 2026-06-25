import Foundation

/// A database file discovered on the device for an app.
struct RemoteDB: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String   // file name, e.g. "app.db"
    let path: String   // Android: "databases/app.db"; iOS Sim: absolute container path
}

/// A table in the (pulled) database, with its row count.
struct DBTable: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let rowCount: Int
}

/// The result of a query: ordered columns and rows (a nil cell is SQL NULL).
struct DBResultSet: Sendable {
    let columns: [String]
    let rows: [[String?]]
}

enum DBError: Error, LocalizedError {
    case notDebuggable
    case command(String)
    case sqlite(String)
    case unsupportedPlatform
    case readOnly

    var errorDescription: String? {
        switch self {
        case .notDebuggable:
            return "The app must be debuggable to read its database (run-as failed)."
        case .command(let m): return m
        case .sqlite(let m): return "SQLite: \(m)"
        case .unsupportedPlatform:
            return "Database browsing isn't supported on this platform yet."
        case .readOnly:
            return "Only read-only queries (SELECT/WITH/PRAGMA/EXPLAIN) are allowed."
        }
    }
}
