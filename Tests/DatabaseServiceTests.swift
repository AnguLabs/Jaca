import XCTest
@testable import Jaca

final class DatabaseServiceTests: XCTestCase {

    // MARK: - Read-only guard

    func test_isReadOnly_allowsSelectWithPragmaExplain() {
        XCTAssertTrue(DatabaseService.isReadOnly("SELECT * FROM users"))
        XCTAssertTrue(DatabaseService.isReadOnly("  select 1"))
        XCTAssertTrue(DatabaseService.isReadOnly("WITH x AS (SELECT 1) SELECT * FROM x"))
        XCTAssertTrue(DatabaseService.isReadOnly("PRAGMA table_info(users)"))
        XCTAssertTrue(DatabaseService.isReadOnly("EXPLAIN QUERY PLAN SELECT 1"))
    }

    func test_isReadOnly_rejectsWrites() {
        XCTAssertFalse(DatabaseService.isReadOnly("DELETE FROM users"))
        XCTAssertFalse(DatabaseService.isReadOnly("UPDATE users SET x = 1"))
        XCTAssertFalse(DatabaseService.isReadOnly("INSERT INTO users VALUES (1)"))
        XCTAssertFalse(DatabaseService.isReadOnly("DROP TABLE users"))
        XCTAssertFalse(DatabaseService.isReadOnly("  "))
    }

    // MARK: - DB file filtering

    func test_parseDBNames_dropsWalShmJournalAndBlanks() {
        let svc = DatabaseService(adbURL: nil)
        let out = """
        app.db
        app.db-wal
        app.db-shm
        app.db-journal

        sessions.sqlite
        """
        XCTAssertEqual(svc.parseDBNames(out), ["app.db", "sessions.sqlite"])
    }

    // MARK: - SQLite read (round-trip on a temp DB built with the system sqlite3)

    func test_readsTablesAndRows_fromRealSqliteFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jaca-db-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("t.db")

        // Build a DB with the system sqlite3 CLI.
        let sql = "CREATE TABLE people(id INTEGER, name TEXT, note TEXT); " +
                  "INSERT INTO people VALUES (1,'Ada',NULL); INSERT INTO people VALUES (2,'Grace','hi');"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [dbURL.path, sql]
        try p.run(); p.waitUntilExit()
        try XCTSkipUnless(p.terminationStatus == 0, "sqlite3 CLI unavailable")

        let svc = DatabaseService(adbURL: nil)
        let tables = try svc.tables(localDB: dbURL)
        XCTAssertEqual(tables.map(\.name), ["people"])
        XCTAssertEqual(tables.first?.rowCount, 2)

        let rs = try svc.rows(localDB: dbURL, table: "people", limit: 10, offset: 0)
        XCTAssertEqual(rs.columns, ["id", "name", "note"])
        XCTAssertEqual(rs.rows.count, 2)
        XCTAssertEqual(rs.rows[0], ["1", "Ada", nil])      // NULL preserved as nil
        XCTAssertEqual(rs.rows[1], ["2", "Grace", "hi"])
    }
}
