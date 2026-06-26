import Foundation
import SQLite3

/// Browses an app's local SQLite database. Discovery + pull happen over adb (Android,
/// debuggable apps via `run-as`) or the simulator container (iOS Simulator); the pulled
/// copy is read with the system `SQLite3` module, opened **read-only**. The whole thing
/// is a snapshot — the caller re-pulls on refresh.
struct DatabaseService: Sendable {
    let adbURL: URL?

    // MARK: - Discovery

    func listDatabases(device: Device, appID: String) async throws -> [RemoteDB] {
        switch device.platform {
        case .android:      return try await androidList(serial: device.id, pkg: appID)
        case .iosSimulator: return try await simulatorList(udid: device.id, bundle: appID)
        case .iosDevice:    throw DBError.unsupportedPlatform
        }
    }

    private func androidList(serial: String, pkg: String) async throws -> [RemoteDB] {
        guard let adbURL else { throw DBError.command("adb not found") }
        guard let r = try? await CommandRunner.run(
            adbURL, ["-s", serial, "shell", "run-as", pkg, "ls", "-1", "databases"]
        ) else { throw DBError.command("adb failed") }

        let err = r.stderr.lowercased() + r.stdout.lowercased()
        if r.exitCode != 0 {
            if err.contains("not debuggable") || err.contains("unknown package") || err.contains("package not") {
                throw DBError.notDebuggable
            }
            if err.contains("no such file") { return [] }
        }
        return parseDBNames(r.stdout).map { RemoteDB(name: $0, path: "databases/\($0)") }
    }

    private func simulatorList(udid: String, bundle: String) async throws -> [RemoteDB] {
        guard let r = try? await CommandRunner.run(
            AppleToolchain.xcrun, ["simctl", "get_app_container", udid, bundle, "data"],
            environment: AppleToolchain.environment()
        ), r.exitCode == 0 else { throw DBError.command("couldn't locate the app container") }

        let container = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !container.isEmpty else { return [] }
        let find = try? await CommandRunner.run(
            URL(fileURLWithPath: "/usr/bin/find"),
            [container, "-type", "f", "(", "-name", "*.sqlite", "-o", "-name", "*.sqlite3", "-o", "-name", "*.db", ")"]
        )
        let paths = (find?.stdout ?? "")
            .split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        return paths.map { RemoteDB(name: ($0 as NSString).lastPathComponent, path: $0) }
    }

    /// Keeps real DB files; drops the `-wal`/`-shm`/`-journal` siblings and blanks.
    func parseDBNames(_ lsOutput: String) -> [String] {
        lsOutput.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty
                && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") && !$0.hasSuffix("-journal") }
    }

    // MARK: - Pull a local snapshot

    /// Copies the DB (plus its `-wal`/`-shm`) into a fresh temp dir and returns the local
    /// main-file URL. Android uses a shell redirect so the binary is byte-exact.
    func pull(device: Device, db: RemoteDB, appID: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jaca-db-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent(db.name)

        switch device.platform {
        case .android:
            guard let adbURL else { throw DBError.command("adb not found") }
            for suffix in ["", "-wal", "-shm"] {
                let cmd = "\(q(adbURL.path)) -s \(q(device.id)) exec-out run-as \(q(appID)) "
                    + "cat \(q(db.path + suffix)) > \(q(local.path + suffix)) 2>/dev/null"
                let r = try? await CommandRunner.run(URL(fileURLWithPath: "/bin/zsh"), ["-c", cmd])
                if suffix.isEmpty && (r?.exitCode ?? 1) != 0 {
                    throw DBError.command("couldn't pull the database")
                }
            }
        case .iosSimulator:
            for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: db.path + suffix) {
                try? FileManager.default.copyItem(atPath: db.path + suffix, toPath: local.path + suffix)
            }
        case .iosDevice:
            throw DBError.unsupportedPlatform
        }

        guard FileManager.default.fileExists(atPath: local.path),
              (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int) ?? 0 > 0 else {
            throw DBError.command("the pulled database was empty")
        }
        return local
    }

    // MARK: - Read (system SQLite3, read-only)

    func tables(localDB: URL) throws -> [DBTable] {
        try withDB(localDB) { db in
            var names: [String] = []
            try forEachRow(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name") {
                if let n = $0.first.flatMap({ $0 }) { names.append(n) }
            }
            return try names.map { name in
                var count = 0
                try forEachRow(db, "SELECT count(*) FROM \(quoteIdent(name))") {
                    count = $0.first.flatMap { $0 }.flatMap { Int($0) } ?? 0
                }
                return DBTable(name: name, rowCount: count)
            }
        }
    }

    func rows(localDB: URL, table: String, limit: Int, offset: Int) throws -> DBResultSet {
        try query(localDB: localDB, sql: "SELECT * FROM \(quoteIdent(table)) LIMIT \(max(0, limit)) OFFSET \(max(0, offset))")
    }

    func query(localDB: URL, sql: String) throws -> DBResultSet {
        try withDB(localDB) { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DBError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            let n = Int(sqlite3_column_count(stmt))
            let columns = (0..<n).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
            var rows: [[String?]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append((0..<n).map { i in cellValue(stmt, Int32(i)) })
            }
            return DBResultSet(columns: columns, rows: rows)
        }
    }

    /// True when `sql` is a read-only statement (cheap pre-check; the read-only handle is
    /// the real guard). Leading SQL comments are skipped first, since generated queries often
    /// open with `-- explanatory` lines before the real keyword.
    static func isReadOnly(_ sql: String) -> Bool {
        let t = stripLeadingComments(sql).lowercased()
        return t.hasPrefix("select") || t.hasPrefix("with")
            || t.hasPrefix("pragma") || t.hasPrefix("explain")
    }

    /// Drops leading whitespace and SQL comments (`-- line` and `/* block */`) so the first real
    /// keyword can be inspected.
    static func stripLeadingComments(_ sql: String) -> String {
        var s = Substring(sql)
        while true {
            let before = s
            s = s.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
            if s.hasPrefix("--") {
                if let nl = s.firstIndex(of: "\n") { s = s[s.index(after: nl)...] } else { s = s[s.endIndex...] }
            } else if s.hasPrefix("/*") {
                if let end = s.range(of: "*/") { s = s[end.upperBound...] } else { s = s[s.endIndex...] }
            }
            if s == before { break }
        }
        return String(s)
    }

    // MARK: - SQLite helpers

    private func withDB<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "couldn't open the database"
            sqlite3_close(handle)
            throw DBError.sqlite(msg)
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func forEachRow(_ db: OpaquePointer, _ sql: String, _ each: ([String?]) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let n = Int(sqlite3_column_count(stmt))
        while sqlite3_step(stmt) == SQLITE_ROW {
            each((0..<n).map { cellValue(stmt, Int32($0)) })
        }
    }

    private func cellValue(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        switch sqlite3_column_type(stmt, col) {
        case SQLITE_NULL: return nil
        case SQLITE_BLOB: return "⟨blob \(sqlite3_column_bytes(stmt, col))B⟩"
        default:
            guard let text = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: text)
        }
    }

    private func quoteIdent(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
