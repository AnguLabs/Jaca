import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Per-session SQLite store of Cloud Logging entries (req 13), so the SQL mode can run
/// arbitrary read-only queries — including the flow-window analysis of req 14 — over a
/// session's captured logs. Mirrors `HistoryStore`: system `libsqlite3`, WAL, batched
/// inserts in a transaction. Writes go through this actor; the SQL mode reads the same file
/// through a separate **read-only** handle (`DatabaseService.query`), which WAL allows
/// concurrently. The file lives under Application Support and is deleted when the tab closes.
actor CloudLogDatabase {
    private var db: OpaquePointer?
    private var insertStmt: OpaquePointer?
    nonisolated let fileURL: URL

    init?(sessionID: UUID, url: URL? = nil) {
        let dbURL: URL
        if let url {
            dbURL = url
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Jaca/cloud-logging/sessions", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            dbURL = base.appendingPathComponent("\(sessionID.uuidString).sqlite")
        }
        self.fileURL = dbURL
        guard sqlite3_open_v2(
            dbURL.path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK else { return nil }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        migrate()
        prepareInsert()
    }

    deinit {
        if insertStmt != nil { sqlite3_finalize(insertStmt) }
        if db != nil { sqlite3_close(db) }
    }

    // MARK: - Schema

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS log_entry(
            id INTEGER PRIMARY KEY AUTOINCREMENT, seq INTEGER, insert_id TEXT,
            ts REAL, receive_ts REAL, severity INTEGER, severity_name TEXT,
            log_id TEXT, log_name TEXT, text_payload TEXT, payload_kind TEXT,
            labels_json TEXT, resource_type TEXT, resource_labels_json TEXT,
            trace TEXT, span_id TEXT, raw TEXT
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_entry_ts ON log_entry(ts);")
        exec("CREATE INDEX IF NOT EXISTS idx_entry_sev ON log_entry(severity);")
        // De-dupe across overlapping poll windows (empty insertId rows are allowed through).
        exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_entry_insert ON log_entry(insert_id) WHERE insert_id <> '';")

        if exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS entry_fts USING fts5(
            text_payload, content='log_entry', content_rowid='id'
        );
        """) {
            exec("""
            CREATE TRIGGER IF NOT EXISTS entry_ai AFTER INSERT ON log_entry BEGIN
                INSERT INTO entry_fts(rowid, text_payload) VALUES (new.id, new.text_payload);
            END;
            """)
        }
    }

    private func prepareInsert() {
        sqlite3_prepare_v2(db, """
        INSERT OR IGNORE INTO log_entry(
            seq, insert_id, ts, receive_ts, severity, severity_name, log_id, log_name,
            text_payload, payload_kind, labels_json, resource_type, resource_labels_json,
            trace, span_id, raw
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, -1, &insertStmt, nil)
    }

    // MARK: - Writes

    func appendEntries(_ entries: [CloudLogEntry]) {
        guard let insertStmt, !entries.isEmpty else { return }
        exec("BEGIN TRANSACTION;")
        for e in entries {
            sqlite3_reset(insertStmt)
            sqlite3_bind_int64(insertStmt, 1, sqlite3_int64(bitPattern: e.seq))
            bindText(insertStmt, 2, e.insertId)
            sqlite3_bind_double(insertStmt, 3, e.timestamp.timeIntervalSince1970)
            if let rt = e.receiveTimestamp {
                sqlite3_bind_double(insertStmt, 4, rt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(insertStmt, 4)
            }
            sqlite3_bind_int(insertStmt, 5, Int32(e.severity.rawValue))
            bindText(insertStmt, 6, e.severity.apiName)
            bindText(insertStmt, 7, e.logId)
            bindText(insertStmt, 8, e.logName)
            bindText(insertStmt, 9, e.message)
            bindText(insertStmt, 10, e.payloadKind.rawValue)
            bindText(insertStmt, 11, Self.jsonString(e.labels))
            bindText(insertStmt, 12, e.resourceType)
            bindText(insertStmt, 13, Self.jsonString(e.resourceLabels))
            bindText(insertStmt, 14, e.trace ?? "")
            bindText(insertStmt, 15, e.spanId ?? "")
            bindText(insertStmt, 16, e.raw)
            sqlite3_step(insertStmt)
        }
        exec("COMMIT;")
    }

    /// Closes the handle and removes the file (+ WAL/SHM). Call when the tab closes.
    func deleteFile() {
        if insertStmt != nil { sqlite3_finalize(insertStmt); insertStmt = nil }
        if db != nil { sqlite3_close(db); db = nil }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: fileURL.path + suffix)
        }
    }

    // MARK: - sqlite helpers

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private static func jsonString(_ dict: [String: String]) -> String {
        guard !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
