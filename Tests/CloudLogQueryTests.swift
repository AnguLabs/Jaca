import XCTest
@testable import Jaca

final class CloudLogQueryTests: XCTestCase {

    // MARK: - Match-mode terms

    func testMatchModeTerms() {
        XCTAssertEqual(CloudMatchMode.contains.term(field: "textPayload", value: "foo"), #"textPayload:"foo""#)
        XCTAssertEqual(CloudMatchMode.exact.term(field: "textPayload", value: "foo"), #"textPayload="foo""#)
        XCTAssertEqual(CloudMatchMode.regex.term(field: "textPayload", value: "fo+"), #"textPayload=~"fo+""#)
        XCTAssertEqual(CloudMatchMode.notContains.term(field: "textPayload", value: "foo"), #"NOT textPayload:"foo""#)
    }

    func testQuoteEscapesBackslashAndQuote() {
        XCTAssertEqual(CloudFilter.quote(#"a"b\c"#), #""a\"b\\c""#)
    }

    func testQuoteKeyOnlyWhenNeeded() {
        XCTAssertEqual(CloudFilter.quoteKeyIfNeeded("env"), "env")
        XCTAssertEqual(CloudFilter.quoteKeyIfNeeded("run.googleapis.com/x"), #""run.googleapis.com/x""#)
    }

    // MARK: - Clause building

    func testSingleTextConditionNoParens() {
        var q = CloudLogQuery()
        q.textConditions = [TextCondition(mode: .contains, value: "boom")]
        XCTAssertEqual(q.clauses(), [#"textPayload:"boom""#])
    }

    func testMultipleTextConditionsOrGrouped() {
        var q = CloudLogQuery()
        q.textConditions = [TextCondition(mode: .contains, value: "a"), TextCondition(mode: .contains, value: "b")]
        q.textCombineOr = true
        XCTAssertEqual(q.clauses(), [#"(textPayload:"a" OR textPayload:"b")"#])
    }

    func testMultipleTextConditionsAndGrouped() {
        var q = CloudLogQuery()
        q.textConditions = [TextCondition(mode: .contains, value: "a"), TextCondition(mode: .exact, value: "b")]
        q.textCombineOr = false
        XCTAssertEqual(q.clauses(), [#"(textPayload:"a" AND textPayload="b")"#])
    }

    func testEmptyTextConditionsSkipped() {
        var q = CloudLogQuery()
        q.textConditions = [TextCondition(mode: .contains, value: "")]
        XCTAssertTrue(q.clauses().isEmpty)
    }

    func testMinSeverity() {
        var q = CloudLogQuery()
        q.minSeverity = .warning
        XCTAssertEqual(q.clauses(), ["severity>=WARNING"])
    }

    func testMinSeverityDefaultProducesNoClause() {
        var q = CloudLogQuery()
        q.minSeverity = .default
        XCTAssertTrue(q.clauses().isEmpty)
    }

    func testSeveritySetSingleAndMultiple() {
        var q = CloudLogQuery()
        q.severitySet = [.error]
        XCTAssertEqual(q.clauses(), ["severity=ERROR"])
        q.severitySet = [.error, .critical]
        XCTAssertEqual(q.clauses(), ["severity=(ERROR OR CRITICAL)"])
    }

    func testSeveritySetWinsOverMin() {
        var q = CloudLogQuery()
        q.minSeverity = .info
        q.severitySet = [.error]
        XCTAssertEqual(q.clauses(), ["severity=ERROR"])
    }

    func testLabelConditionScopesAndModes() {
        var q = CloudLogQuery()
        q.labelConditions = [LabelCondition(key: "env", scope: .entry, mode: .exact, value: "prod")]
        XCTAssertEqual(q.clauses(), [#"labels.env="prod""#])

        q.labelConditions = [LabelCondition(key: "zone", scope: .resource, mode: .contains, value: "us")]
        XCTAssertEqual(q.clauses(), [#"resource.labels.zone:"us""#])
    }

    func testLabelKeyWithDotsQuoted() {
        var q = CloudLogQuery()
        q.labelConditions = [LabelCondition(key: "a.b", scope: .entry, mode: .exact, value: "x")]
        XCTAssertEqual(q.clauses(), [#"labels."a.b"="x""#])
    }

    func testMultipleLabelsOrGrouped() {
        var q = CloudLogQuery()
        q.labelConditions = [
            LabelCondition(key: "env", scope: .entry, mode: .exact, value: "prod"),
            LabelCondition(key: "env", scope: .entry, mode: .exact, value: "staging"),
        ]
        q.labelCombineOr = true
        XCTAssertEqual(q.clauses(), [#"(labels.env="prod" OR labels.env="staging")"#])
    }

    func testEmptyQueryIsEmpty() {
        XCTAssertTrue(CloudLogQuery().isEmpty)
    }

    // MARK: - Full filter assembly

    func testBuildAndsLogNameTimeAndQuery() {
        var q = CloudLogQuery()
        q.textConditions = [TextCondition(mode: .contains, value: "x")]
        q.minSeverity = .error
        let filter = CloudFilter.build(
            logName: "projects/p/logs/stdout",
            time: #"timestamp>="2024-06-26T10:00:00.000Z""#,
            query: q
        )
        XCTAssertEqual(
            filter,
            #"logName="projects/p/logs/stdout" AND timestamp>="2024-06-26T10:00:00.000Z" AND textPayload:"x" AND severity>=ERROR"#
        )
    }

    func testBuildOmitsEmptyParts() {
        XCTAssertEqual(CloudFilter.build(logName: nil, time: nil, query: CloudLogQuery()), "")
        XCTAssertEqual(
            CloudFilter.build(logName: "projects/p/logs/stdout", time: nil, query: CloudLogQuery()),
            #"logName="projects/p/logs/stdout""#
        )
    }

    // MARK: - Log names

    func testLogNameFullEncodesSlash() {
        XCTAssertEqual(CloudLogName.full(projectID: "p", logName: "stdout"), "projects/p/logs/stdout")
        XCTAssertEqual(
            CloudLogName.full(projectID: "p", logName: "run.googleapis.com/stdout"),
            "projects/p/logs/run.googleapis.com%2Fstdout"
        )
    }

    func testLogNameFullPassThroughWhenAlreadyFull() {
        XCTAssertEqual(
            CloudLogName.full(projectID: "p", logName: "projects/other/logs/x"),
            "projects/other/logs/x"
        )
    }

    func testLogNameShortIdDecodes() {
        XCTAssertEqual(CloudLogName.shortId("projects/p/logs/run.googleapis.com%2Fstdout"), "run.googleapis.com/stdout")
        XCTAssertEqual(CloudLogName.shortId("stdout"), "stdout")
    }
}
