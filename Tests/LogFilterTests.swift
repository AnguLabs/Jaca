import XCTest
@testable import Jaca

final class LogFilterTests: XCTestCase {
    private func line(
        level: LogLevel = .info, tag: String = "Tag", pid: Int32 = 100, message: String = "hello world"
    ) -> LogLine {
        LogLine(seq: 0, timestamp: Date(), level: level, tag: tag, pid: pid,
                tid: 1, message: message, raw: "", processName: nil)
    }

    func testEmptyFilterMatchesEverything() {
        let f = LogFilter()
        XCTAssertTrue(f.isEmpty)
        XCTAssertTrue(f.matches(line(level: .verbose), regex: nil))
    }

    func testMinLevelExcludesLower() {
        var f = LogFilter(); f.minLevel = .warn
        XCTAssertFalse(f.matches(line(level: .info), regex: nil))
        XCTAssertTrue(f.matches(line(level: .error), regex: nil))
    }

    func testTextQueryCaseInsensitiveOverMessageAndTag() {
        var f = LogFilter(); f.query = "WORLD"
        XCTAssertTrue(f.matches(line(message: "hello world"), regex: nil))
        f.query = "tag"
        XCTAssertTrue(f.matches(line(tag: "MyTag"), regex: nil))
        f.query = "absent"
        XCTAssertFalse(f.matches(line(), regex: nil))
    }

    func testPIDFilter() {
        var f = LogFilter(); f.pids = [200, 300]
        XCTAssertFalse(f.matches(line(pid: 100), regex: nil))
        XCTAssertTrue(f.matches(line(pid: 200), regex: nil))
    }

    func testRegexQuery() {
        var f = LogFilter(); f.isRegex = true; f.query = #"hel+o"#
        let rx = f.compiledRegex()
        XCTAssertNotNil(rx)
        XCTAssertTrue(f.matches(line(message: "hello"), regex: rx))
        XCTAssertFalse(f.matches(line(message: "hi"), regex: rx))
    }

    func testInvalidRegexMatchesNothing() {
        var f = LogFilter(); f.isRegex = true; f.query = "[unclosed"
        XCTAssertNil(f.compiledRegex())
        XCTAssertFalse(f.matches(line(message: "anything"), regex: nil))
    }
}

extension LogFilterTests {
    private func line(tag: String, pid: Int32 = 1) -> LogLine {
        LogLine(seq: 0, timestamp: Date(), level: .info, tag: tag, pid: pid, tid: 0, message: "m", raw: "m")
    }
    func testHideSystemLogsDropsAppleSubsystems() {
        var f = LogFilter()                      // hideSystemLogs defaults true
        XCTAssertFalse(f.matches(line(tag: "com.apple.network"), regex: nil))
        XCTAssertFalse(f.matches(line(tag: "com.apple.CFNetwork"), regex: nil))
        XCTAssertTrue(f.matches(line(tag: "com.example.haapi"), regex: nil))   // app subsystem
        XCTAssertTrue(f.matches(line(tag: ""), regex: nil))                  // NSLog / no subsystem
        f.hideSystemLogs = false
        XCTAssertTrue(f.matches(line(tag: "com.apple.network"), regex: nil))
    }
}
