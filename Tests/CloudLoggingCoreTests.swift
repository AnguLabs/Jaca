import XCTest
@testable import Jaca

final class CloudLoggingCoreTests: XCTestCase {

    private func entry(_ insertId: String, labels: [String: String] = [:]) -> CloudLogEntry {
        CloudLogEntry(insertId: insertId, timestamp: Date(), receiveTimestamp: nil,
                      severity: .info, logName: "projects/p/logs/x", logId: "x", message: "m",
                      payloadKind: .text, labels: labels, resourceType: "", resourceLabels: [:],
                      trace: nil, spanId: nil, httpRequestSummary: nil, raw: "")
    }

    // MARK: - CloudSeverity

    func testSeverityOrdering() {
        XCTAssertLessThan(CloudSeverity.debug, .info)
        XCTAssertLessThan(CloudSeverity.info, .warning)
        XCTAssertLessThan(CloudSeverity.warning, .error)
        XCTAssertLessThan(CloudSeverity.error, .critical)
        XCTAssertGreaterThan(CloudSeverity.emergency, .error)
    }

    func testSeverityParse() {
        XCTAssertEqual(CloudSeverity(apiValue: "ERROR"), .error)
        XCTAssertEqual(CloudSeverity(apiValue: "warning"), .warning)
        XCTAssertEqual(CloudSeverity(apiValue: nil), .default)
        XCTAssertEqual(CloudSeverity(apiValue: "bogus"), .default)
        XCTAssertEqual(CloudSeverity.error.apiName, "ERROR")
    }

    // MARK: - CloudTimeRange

    func testTimeRangeIsLive() {
        XCTAssertTrue(CloudTimeRange.last(minutes: 15).isLive)
        XCTAssertFalse(CloudTimeRange.between(start: Date(), end: Date()).isLive)
    }

    func testTimeRangeStartAndClause() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let range = CloudTimeRange.last(minutes: 15)
        XCTAssertEqual(range.start(now: now).timeIntervalSince1970, 1_000_000 - 900, accuracy: 0.001)
        XCTAssertTrue(range.clause(now: now).hasPrefix("timestamp>="))
    }

    func testTimeRangeBetweenClauseHasBothBounds() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = Date(timeIntervalSince1970: 1_000_100)
        let clause = CloudTimeRange.between(start: start, end: end).clause(now: Date())
        XCTAssertTrue(clause.contains("timestamp>="))
        XCTAssertTrue(clause.contains("timestamp<="))
    }

    func testTimeRangeLabel() {
        XCTAssertEqual(CloudTimeRange.last(minutes: 15).label, "Last 15m")
        XCTAssertEqual(CloudTimeRange.last(minutes: 120).label, "Last 2h")
        XCTAssertEqual(CloudTimeRange.between(start: Date(), end: Date()).label, "Custom range")
    }

    // MARK: - LabelDetector

    func testLabelKeysExtracted() {
        let keys = LabelDetector.keys(in: [entry("a", labels: ["env": "prod", "v": "1"]),
                                           entry("b", labels: ["env": "prod", "region": "eu"])])
        XCTAssertEqual(keys, ["env", "v", "region"])
    }

    func testLabelMergeReportsChange() {
        let (merged1, changed1) = LabelDetector.merge(["env"], with: ["env", "region"])
        XCTAssertEqual(merged1, ["env", "region"])
        XCTAssertTrue(changed1)

        let (merged2, changed2) = LabelDetector.merge(["env", "region"], with: ["env"])
        XCTAssertEqual(merged2, ["env", "region"])
        XCTAssertFalse(changed2)
    }

    // MARK: - InsertIdWindow (poller dedup)

    func testInsertIdWindowDedups() {
        var window = InsertIdWindow()
        XCTAssertEqual(window.fresh([entry("a"), entry("b")]).map(\.insertId), ["a", "b"])
        XCTAssertEqual(window.fresh([entry("b"), entry("c")]).map(\.insertId), ["c"])
        XCTAssertEqual(window.fresh([entry("a"), entry("c")]).map(\.insertId), [])
    }

    func testInsertIdWindowEmptyIdsAlwaysPass() {
        var window = InsertIdWindow()
        XCTAssertEqual(window.fresh([entry(""), entry("")]).count, 2)
    }

    func testInsertIdWindowEvictsBeyondCap() {
        var window = InsertIdWindow(cap: 2)
        _ = window.fresh([entry("a"), entry("b")])
        _ = window.fresh([entry("c")])           // evicts "a"
        XCTAssertEqual(window.fresh([entry("a")]).map(\.insertId), ["a"])  // "a" re-appears as fresh
        XCTAssertEqual(window.fresh([entry("c")]).map(\.insertId), [])     // "c" still remembered
    }

    // MARK: - CloudTimestamp

    func testTimestampNormalizeFraction() {
        XCTAssertEqual(CloudTimestamp.normalizeFraction("2024-06-26T10:00:00.123456789Z"), "2024-06-26T10:00:00.123Z")
        XCTAssertEqual(CloudTimestamp.normalizeFraction("2024-06-26T10:00:00.5Z"), "2024-06-26T10:00:00.500Z")
        XCTAssertEqual(CloudTimestamp.normalizeFraction("2024-06-26T10:00:00Z"), "2024-06-26T10:00:00Z")
    }

    func testTimestampParsesNanosecondPrecision() {
        XCTAssertNotNil(CloudTimestamp.parse("2024-06-26T10:00:00.123456789Z"))
        XCTAssertNotNil(CloudTimestamp.parse("2024-06-26T10:00:00Z"))
        XCTAssertNil(CloudTimestamp.parse("not-a-date"))
    }

    func testTimestampQuoteRoundTrips() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let quoted = CloudTimestamp.quote(date)
        XCTAssertTrue(quoted.hasPrefix("\""))
        XCTAssertTrue(quoted.hasSuffix("\""))
        let inner = String(quoted.dropFirst().dropLast())
        XCTAssertNotNil(CloudTimestamp.parse(inner))
    }
}
