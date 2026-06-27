import XCTest
@testable import Jaca

/// The SQL-mode list maps result rows back to captured entries and turns marker/unmapped rows
/// into synthetic dividers (so a query can inject `----- window -----` separators).
final class CloudSqlMappingTests: XCTestCase {

    private func entry(seq: UInt64, insertId: String, message: String = "m") -> CloudLogEntry {
        CloudLogEntry(seq: seq, insertId: insertId, timestamp: Date(), receiveTimestamp: nil,
                      severity: .info, logName: "projects/p/logs/x", logId: "x", message: message,
                      payloadKind: .text, labels: [:], resourceType: "", resourceLabels: [:],
                      trace: nil, spanId: nil, httpRequestSummary: nil, raw: "")
    }

    private let columns = ["insert_id", "seq", "time", "severity_name", "text_payload", "is_marker"]

    func test_columnResolution() {
        let cols = SqlResultColumns(columns)
        XCTAssertEqual(cols.idCol, 0)
        XCTAssertEqual(cols.seqCol, 1)
        XCTAssertEqual(cols.messageCol, 4)
        XCTAssertEqual(cols.severityCol, 3)
        XCTAssertEqual(cols.markerCol, 5)
        XCTAssertTrue(cols.isMarker(["", "2", nil, "NOTICE", "x", "1"]))
        XCTAssertFalse(cols.isMarker(["b", "2", nil, "INFO", "x", "0"]))
    }

    /// Two flow windows with a divider before each — matches the verified flow-window template output.
    func test_flowWindow_realRowsAndDividers() {
        let ring = [entry(seq: 2, insertId: "b"), entry(seq: 3, insertId: "c"),
                    entry(seq: 4, insertId: "d"), entry(seq: 7, insertId: "g"),
                    entry(seq: 8, insertId: "h")]
        let rows: [[String?]] = [
            ["",  "2", nil, "NOTICE", "----- window -----", "1"],
            ["b", "2", nil, "INFO",   "flow START checkout", "0"],
            ["c", "3", nil, "INFO",   "validating cart",     "0"],
            ["d", "4", nil, "INFO",   "charging card",       "0"],
            ["",  "7", nil, "NOTICE", "----- window -----", "1"],
            ["g", "7", nil, "INFO",   "flow START login",    "0"],
            ["h", "8", nil, "INFO",   "check password",      "0"],
        ]
        let out = CloudLogSession.mapSqlRows(columns: SqlResultColumns(columns), rows: rows, ring: ring, search: "")

        XCTAssertEqual(out.count, 7)
        XCTAssertTrue(out[0].isSynthetic)
        XCTAssertEqual(out[0].message, "----- window -----")
        XCTAssertEqual(out[0].severity, .notice)
        XCTAssertFalse(out[1].isSynthetic)
        XCTAssertEqual(out[1].insertId, "b")
        XCTAssertTrue(out[4].isSynthetic)
        XCTAssertFalse(out[5].isSynthetic)
        XCTAssertEqual(out[5].insertId, "g")
        // Synthetic ids are unique and live at the top of the range (never collide with real seqs).
        XCTAssertEqual(out[0].seq, UInt64.max)
        XCTAssertEqual(out[4].seq, UInt64.max - 1)
        XCTAssertNotEqual(out[0].seq, out[4].seq)
    }

    /// A LIMIT must be honoured exactly — the regression that started this whole thread.
    func test_limitIsRespected() {
        let ring = (1...25).map { entry(seq: UInt64($0), insertId: "id\($0)") }
        let rows: [[String?]] = [["id25", "25", nil, "INFO", "m", "0"],
                                 ["id24", "24", nil, "INFO", "m", "0"]]   // LIMIT 2
        let out = CloudLogSession.mapSqlRows(columns: SqlResultColumns(columns), rows: rows, ring: ring, search: "")
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map(\.insertId), ["id25", "id24"])
    }

    /// Older pages (oldest-first) get strictly-increasing seqs that all sit below the current
    /// minimum, so the ring stays sorted ascending = chronological after prepending.
    func test_assignOlderSeqs_belowMinimumAndAscending() {
        let page = [entry(seq: 0, insertId: "a"), entry(seq: 0, insertId: "b"), entry(seq: 0, insertId: "c")]
        let out = CloudLogSession.assignOlderSeqs(page, below: 1000, stride: 8)
        XCTAssertEqual(out.map(\.seq), [976, 984, 992])      // ascending, all < 1000
        XCTAssertEqual(out.map(\.insertId), ["a", "b", "c"]) // order preserved
        XCTAssertLessThan(out.last!.seq, 1000)               // newest still below the old minimum
    }

    /// A row with an empty insert_id that maps to nothing (and no marker column) still renders as a
    /// synthetic line built from its text_payload.
    func test_unmappedRow_becomesSyntheticByFallback() {
        let cols = SqlResultColumns(["insert_id", "seq", "severity_name", "text_payload"])
        let rows: [[String?]] = [["", "999", "WARNING", "orphan line"]]
        let out = CloudLogSession.mapSqlRows(columns: cols, rows: rows, ring: [], search: "")
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].isSynthetic)
        XCTAssertEqual(out[0].message, "orphan line")
        XCTAssertEqual(out[0].severity, .warning)
    }
}
