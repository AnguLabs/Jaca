import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A distinct device+package that has saved history (groups the browser's left pane).
struct PackageGroup: Identifiable, Sendable, Hashable {
    let deviceID: String
    let model: String
    let package: String
    let sessions: Int
    var id: String { deviceID + "\u{1}" + package }
    var displayPackage: String { package.isEmpty ? "(no package filter)" : package }
}

/// A persisted log session (one tab's run), used by the history browser.
struct SessionRecord: Identifiable, Sendable, Hashable {
    let id: String
    let deviceID: String
    let deviceModel: String
    let package: String
    let displayName: String
    let startedAt: Date
    let endedAt: Date?
    let lineCount: Int
}

/// SQLite-backed history of every logcat session, queryable by device + package
/// across sessions. Uses the system `libsqlite3` (no dependency). All access is
/// serialized through the actor; inserts are batched by the caller (~200ms).
actor HistoryStore {
    private var db: OpaquePointer?
    private var insertStmt: OpaquePointer?
    private var hasFTS = false

    /// Opens (creating if needed) the history DB under Application Support.
    /// Returns nil only if the database can't be opened at all.
    init?(url: URL? = nil) {
        let dbURL: URL
        if let url {
            dbURL = url
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Squeeze", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            dbURL = base.appendingPathComponent("history.sqlite")
        }
        guard sqlite3_open_v2(
            dbURL.path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK else {
            return nil
        }
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
        CREATE TABLE IF NOT EXISTS device(
            id TEXT PRIMARY KEY, platform TEXT, model TEXT,
            first_seen REAL, last_seen REAL
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS session(
            id TEXT PRIMARY KEY, device_id TEXT, package TEXT, display_name TEXT,
            started_at REAL, ended_at REAL
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS log_line(
            id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, seq INTEGER,
            ts REAL, level INTEGER, tag TEXT, pid INTEGER, tid INTEGER,
            process TEXT, message TEXT
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_log_session ON log_line(session_id, seq);")
        exec("CREATE INDEX IF NOT EXISTS idx_session_device ON session(device_id, package);")

        // FTS5 over message (external content). Falls back to LIKE if unavailable.
        if exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS log_fts USING fts5(
            message, content='log_line', content_rowid='id'
        );
        """) {
            hasFTS = true
            exec("""
            CREATE TRIGGER IF NOT EXISTS log_ai AFTER INSERT ON log_line BEGIN
                INSERT INTO log_fts(rowid, message) VALUES (new.id, new.message);
            END;
            """)
            exec("""
            CREATE TRIGGER IF NOT EXISTS log_ad AFTER DELETE ON log_line BEGIN
                INSERT INTO log_fts(log_fts, rowid, message) VALUES('delete', old.id, old.message);
            END;
            """)
        }
    }

    private func prepareInsert() {
        sqlite3_prepare_v2(db, """
        INSERT INTO log_line(session_id, seq, ts, level, tag, pid, tid, process, message)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, -1, &insertStmt, nil)
    }

    // MARK: - Writes

    func upsertDevice(_ device: Device, at date: Date = Date()) {
        let stmt = prepare("""
        INSERT INTO device(id, platform, model, first_seen, last_seen)
        VALUES (?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET model=excluded.model, last_seen=excluded.last_seen;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, device.id)
        bindText(stmt, 2, device.platform.rawValue)
        bindText(stmt, 3, device.model)
        sqlite3_bind_double(stmt, 4, date.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 5, date.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    func beginSession(id: UUID, device: Device, package: String, displayName: String, startedAt: Date = Date()) {
        let stmt = prepare("""
        INSERT OR REPLACE INTO session(id, device_id, package, display_name, started_at, ended_at)
        VALUES (?,?,?,?,?,NULL);
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        bindText(stmt, 2, device.id)
        bindText(stmt, 3, package)
        bindText(stmt, 4, displayName)
        sqlite3_bind_double(stmt, 5, startedAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    func endSession(id: UUID, at date: Date = Date()) {
        let stmt = prepare("UPDATE session SET ended_at=? WHERE id=?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        bindText(stmt, 2, id.uuidString)
        sqlite3_step(stmt)
    }

    func appendLines(sessionID: UUID, _ lines: [LogLine]) {
        guard let insertStmt, !lines.isEmpty else { return }
        exec("BEGIN TRANSACTION;")
        let sid = sessionID.uuidString
        for line in lines {
            sqlite3_reset(insertStmt)
            bindText(insertStmt, 1, sid)
            sqlite3_bind_int64(insertStmt, 2, sqlite3_int64(line.seq))
            sqlite3_bind_double(insertStmt, 3, line.timestamp.timeIntervalSince1970)
            sqlite3_bind_int(insertStmt, 4, Int32(line.level.rawValue))
            bindText(insertStmt, 5, line.tag)
            sqlite3_bind_int(insertStmt, 6, line.pid)
            sqlite3_bind_int(insertStmt, 7, line.tid)
            bindText(insertStmt, 8, line.processName ?? "")
            bindText(insertStmt, 9, line.message)
            sqlite3_step(insertStmt)
        }
        exec("COMMIT;")
    }

    /// Deletes sessions (and their lines via the FTS delete trigger) started
    /// before `cutoff`. Run on launch for retention.
    func prune(olderThan cutoff: Date) {
        let ts = cutoff.timeIntervalSince1970
        let stmt = prepare("SELECT id FROM session WHERE started_at < ?;")
        var ids: [String] = []
        if let stmt {
            sqlite3_bind_double(stmt, 1, ts)
            while sqlite3_step(stmt) == SQLITE_ROW { ids.append(text(stmt, 0)) }
            sqlite3_finalize(stmt)
        }
        for id in ids {
            let del = prepare("DELETE FROM log_line WHERE session_id=?;")
            bindText(del, 1, id); sqlite3_step(del); sqlite3_finalize(del)
        }
        let delSessions = prepare("DELETE FROM session WHERE started_at < ?;")
        sqlite3_bind_double(delSessions, 1, ts); sqlite3_step(delSessions); sqlite3_finalize(delSessions)
        exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    /// Deletes a single session and its lines.
    func deleteSession(id: UUID) {
        let sid = id.uuidString
        let del = prepare("DELETE FROM log_line WHERE session_id=?;")
        bindText(del, 1, sid); sqlite3_step(del); sqlite3_finalize(del)
        let delS = prepare("DELETE FROM session WHERE id=?;")
        bindText(delS, 1, sid); sqlite3_step(delS); sqlite3_finalize(delS)
    }

    // MARK: - Reads

    /// Sessions for a device, optionally filtered to one package, newest first.
    func sessions(deviceID: String, package: String? = nil) -> [SessionRecord] {
        var sql = """
        SELECT s.id, s.device_id, COALESCE(d.model,''), s.package, s.display_name,
               s.started_at, s.ended_at, (SELECT COUNT(*) FROM log_line l WHERE l.session_id=s.id)
        FROM session s LEFT JOIN device d ON d.id = s.device_id
        WHERE s.device_id = ?
        """
        if package != nil { sql += " AND s.package = ?" }
        sql += " ORDER BY s.started_at DESC;"

        let stmt = prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, deviceID)
        if let package { bindText(stmt, 2, package) }

        var out: [SessionRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ended = sqlite3_column_type(stmt, 6) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            out.append(SessionRecord(
                id: text(stmt, 0), deviceID: text(stmt, 1), deviceModel: text(stmt, 2),
                package: text(stmt, 3), displayName: text(stmt, 4),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                endedAt: ended, lineCount: Int(sqlite3_column_int(stmt, 7))
            ))
        }
        return out
    }

    /// Distinct device+package groups that have history, most-recent first.
    func packageGroups() -> [PackageGroup] {
        let stmt = prepare("""
        SELECT s.device_id, COALESCE(d.model,''), s.package, COUNT(*)
        FROM session s LEFT JOIN device d ON d.id = s.device_id
        GROUP BY s.device_id, s.package
        ORDER BY MAX(s.started_at) DESC;
        """)
        defer { sqlite3_finalize(stmt) }
        var out: [PackageGroup] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(PackageGroup(
                deviceID: text(stmt, 0), model: text(stmt, 1),
                package: text(stmt, 2), sessions: Int(sqlite3_column_int(stmt, 3))
            ))
        }
        return out
    }

    /// Lines for a session, optionally full-text searched, oldest first.
    func lines(sessionID: UUID, search: String? = nil, limit: Int = 50_000) -> [LogLine] {
        let sid = sessionID.uuidString
        let stmt: OpaquePointer?
        if let search, !search.isEmpty, hasFTS {
            stmt = prepare("""
            SELECT l.seq, l.ts, l.level, l.tag, l.pid, l.tid, l.process, l.message
            FROM log_line l JOIN log_fts f ON f.rowid = l.id
            WHERE l.session_id = ? AND log_fts MATCH ?
            ORDER BY l.seq ASC LIMIT ?;
            """)
            bindText(stmt, 1, sid)
            bindText(stmt, 2, ftsQuery(search))
            sqlite3_bind_int(stmt, 3, Int32(limit))
        } else if let search, !search.isEmpty {
            stmt = prepare("""
            SELECT seq, ts, level, tag, pid, tid, process, message FROM log_line
            WHERE session_id = ? AND message LIKE ? ORDER BY seq ASC LIMIT ?;
            """)
            bindText(stmt, 1, sid)
            bindText(stmt, 2, "%\(search)%")
            sqlite3_bind_int(stmt, 3, Int32(limit))
        } else {
            stmt = prepare("""
            SELECT seq, ts, level, tag, pid, tid, process, message FROM log_line
            WHERE session_id = ? ORDER BY seq ASC LIMIT ?;
            """)
            bindText(stmt, 1, sid)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [LogLine] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let process = text(stmt, 6)
            out.append(LogLine(
                seq: UInt64(bitPattern: sqlite3_column_int64(stmt, 0)),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                level: LogLevel(rawValue: Int(sqlite3_column_int(stmt, 2))) ?? .info,
                tag: text(stmt, 3),
                pid: sqlite3_column_int(stmt, 4),
                tid: sqlite3_column_int(stmt, 5),
                message: text(stmt, 7),
                raw: "",
                processName: process.isEmpty ? nil : process
            ))
        }
        return out
    }

    // MARK: - sqlite helpers

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    /// Escapes a free-text query for FTS5 (quote each token, prefix-match).
    private func ftsQuery(_ search: String) -> String {
        let tokens = search.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !tokens.isEmpty else { return "\"\(search)\"" }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}
