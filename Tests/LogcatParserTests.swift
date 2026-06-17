import XCTest
@testable import Jaca

final class LogcatParserTests: XCTestCase {
    func testParsesStandardThreadtimeLine() {
        let raw = "06-07 12:34:56.789  1234  1250 I ActivityManager: Start proc com.foo"
        let line = LogcatParser.parse(raw, year: 2026)
        XCTAssertNotNil(line)
        XCTAssertEqual(line?.level, .info)
        XCTAssertEqual(line?.pid, 1234)
        XCTAssertEqual(line?.tid, 1250)
        XCTAssertEqual(line?.tag, "ActivityManager")
        XCTAssertEqual(line?.message, "Start proc com.foo")
    }

    func testParsesAllLevelChars() {
        let map: [(Character, LogLevel)] = [
            ("V", .verbose), ("D", .debug), ("I", .info),
            ("W", .warn), ("E", .error), ("F", .fatal), ("A", .fatal),
        ]
        for (char, expected) in map {
            let raw = "01-01 00:00:00.000 1 1 \(char) Tag: msg"
            XCTAssertEqual(LogcatParser.parse(raw)?.level, expected, "level \(char)")
        }
    }

    func testStripsOnlyStandardSeparatorPreservingMessageIndentation() {
        // Only the standard "TAG: " separator (colon + one space) is removed; any further
        // leading whitespace is the message's own indentation and survives verbatim.
        XCTAssertEqual(LogcatParser.parse("06-16 22:02:20.050 1 1 D Tag: METHOD: POST")?.message,
                       "METHOD: POST")
        // Pretty-printed JSON body: 2-space indent must be preserved.
        XCTAssertEqual(LogcatParser.parse("06-16 22:02:20.050 1 1 D Http:   \"dimensions\": [")?.message,
                       "  \"dimensions\": [")
        // Java stack frame: leading tab must survive (it's expanded for display elsewhere).
        XCTAssertEqual(LogcatParser.parse("06-16 21:18:54.014 1 1 E WM-WorkerFactory: \tat java.lang.Class.forName(Class.java:502)")?.message,
                       "\tat java.lang.Class.forName(Class.java:502)")
    }

    func testTagWithColonInMessage() {
        let raw = "06-07 12:34:56.789  10  20 E MyTag: key: value: pair"
        let line = LogcatParser.parse(raw)
        XCTAssertEqual(line?.tag, "MyTag")
        XCTAssertEqual(line?.message, "key: value: pair")
    }

    func testNonEntryReturnsNil() {
        XCTAssertNil(LogcatParser.parse("--------- beginning of main"))
        XCTAssertNil(LogcatParser.parse("garbage line without structure"))
    }

    func testParsesYearIntoTimestamp() {
        let line = LogcatParser.parse("06-07 12:34:56.789 1 1 I T: m", year: 2026)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: line!.timestamp)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 7)
    }
}
