import XCTest
@testable import Jaca

final class SimulatorConsoleParserTests: XCTestCase {
    func testRawPrintLineBecomesStdout() {
        let line = SimulatorConsoleParser.parse("Sardine SDK initialized successfully")
        XCTAssertNotNil(line)
        XCTAssertEqual(line?.tag, "stdout")
        XCTAssertEqual(line?.message, "Sardine SDK initialized successfully")
        XCTAssertEqual(line?.level, .info)
        XCTAssertTrue(line?.isConsoleOutput ?? false)
    }

    func testStderrFlagSetsTag() {
        let line = SimulatorConsoleParser.parse("objc[65991]: Class implemented twice", isStderr: true)
        XCTAssertEqual(line?.tag, "stderr")
        XCTAssertTrue(line?.isConsoleOutput ?? false)
    }

    func testNSLogMirrorIsDroppedToAvoidDuplicates() {
        // `timestamp ProcessName[pid:tid] …` is already delivered by `log stream`
        // with full metadata, so the console source drops it.
        let raw = "2026-06-14 19:53:58.395 Teya Dev[65991:17811277] [Firebase/Crashlytics] Version 11.15.0"
        XCTAssertNil(SimulatorConsoleParser.parse(raw))
    }

    func testBracketedPrintLineIsKept() {
        // Brackets but no leading timestamp → genuine stdout, keep it.
        let line = SimulatorConsoleParser.parse("[Braze] configure called (already configured: false)")
        XCTAssertNotNil(line)
        XCTAssertEqual(line?.message, "[Braze] configure called (already configured: false)")
    }

    func testNumericPrintLineIsKept() {
        XCTAssertEqual(SimulatorConsoleParser.parse("Duration: 189261.0")?.message, "Duration: 189261.0")
    }

    func testBlankAndCarriageReturnLinesReturnNil() {
        XCTAssertNil(SimulatorConsoleParser.parse(""))
        XCTAssertNil(SimulatorConsoleParser.parse("   "))
        XCTAssertNil(SimulatorConsoleParser.parse("\r"))
    }

    func testConsoleOutputBypassesPackagePIDFilter() {
        var filter = LogFilter()
        filter.pids = [1234]   // active package filter
        let consoleLine = SimulatorConsoleParser.parse("hello from print()")!
        XCTAssertTrue(filter.matches(consoleLine, regex: nil),
                      "stdout/print lines (no pid) must survive the package PID filter")

        let normalLine = LogLine(seq: 1, timestamp: Date(), level: .info, tag: "T",
                                 pid: 0, tid: 0, message: "x", raw: "x")
        XCTAssertFalse(filter.matches(normalLine, regex: nil),
                       "a non-console line with a non-matching pid is still filtered out")
    }

    func testConsoleOutputStillSubjectToLevelAndQueryFilters() {
        var filter = LogFilter()
        filter.minLevel = .warn
        let info = SimulatorConsoleParser.parse("just info")!
        XCTAssertFalse(filter.matches(info, regex: nil), "console lines still obey min level")

        filter.minLevel = .verbose
        filter.query = "needle"
        XCTAssertFalse(filter.matches(SimulatorConsoleParser.parse("haystack")!, regex: nil))
        XCTAssertTrue(filter.matches(SimulatorConsoleParser.parse("a needle here")!, regex: nil))
    }
}
