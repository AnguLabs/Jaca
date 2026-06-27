import XCTest
@testable import Jaca

final class LogTextLinesTests: XCTestCase {
    func testSingleLineIsOneRow() {
        XCTAssertEqual(LogTextLines.count("hello world"), 1)
        XCTAssertEqual(LogTextLines.displayLines("hello world"), ["hello world"])
    }

    func testEmptyMessageIsOneRow() {
        XCTAssertEqual(LogTextLines.count(""), 1)
        XCTAssertEqual(LogTextLines.displayLines(""), [""])
    }

    func testMultiLineCountsEachLine() {
        XCTAssertEqual(LogTextLines.count("a\nb\nc"), 3)
        XCTAssertEqual(LogTextLines.displayLines("a\nb\nc"), ["a", "b", "c"])
    }

    func testTrailingNewlineDoesNotAddBlankRow() {
        XCTAssertEqual(LogTextLines.count("a\nb\n"), 2)
        XCTAssertEqual(LogTextLines.displayLines("a\nb\n"), ["a", "b"])
        XCTAssertEqual(LogTextLines.count("\n"), 1)
        XCTAssertEqual(LogTextLines.displayLines("\n"), [""])
    }

    func testInteriorBlankLinesPreserved() {
        XCTAssertEqual(LogTextLines.count("a\n\nb"), 3)
        XCTAssertEqual(LogTextLines.displayLines("a\n\nb"), ["a", "", "b"])
    }

    func testCountAndDisplayLinesAlwaysAgree() {
        for msg in ["", "x", "a\nb", "a\nb\n", "\n", "a\n\n\nb",
                    "line\r\nwin", "a\r\nb\r\n", "a\rb", "\r\n"] {
            XCTAssertEqual(LogTextLines.count(msg), LogTextLines.displayLines(msg).count,
                           "disagreement for \(msg.debugDescription)")
        }
    }

    func testCRLFNormalizedToSingleBreak() {
        XCTAssertEqual(LogTextLines.count("line\r\nwin"), 2)
        XCTAssertEqual(LogTextLines.displayLines("line\r\nwin"), ["line", "win"])
        XCTAssertEqual(LogTextLines.count("a\r\nb\r\n"), 2)          // trailing CRLF: no blank row
        XCTAssertEqual(LogTextLines.displayLines("a\r\nb\r\n"), ["a", "b"])
        XCTAssertEqual(LogTextLines.count("a\rb"), 1)               // lone CR stripped, not a break
    }

    func testOverCapCollapsesToIndicator() {
        let big = (0..<(LogTextLines.maxPerEntry + 50)).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertTrue(LogTextLines.isTruncated(big))
        XCTAssertEqual(LogTextLines.count(big), LogTextLines.maxPerEntry)
        let lines = LogTextLines.displayLines(big)
        XCTAssertEqual(lines.count, LogTextLines.maxPerEntry)
        XCTAssertEqual(lines.first, "line 0")
        XCTAssertTrue(lines.last!.contains("more line"), "expected an overflow indicator, got \(lines.last!)")
        // 200 cap → 199 real lines shown + indicator; 250 total → 51 hidden.
        XCTAssertTrue(lines.last!.contains("51"))
    }

    func testExpandsTabsButPreservesSpaceIndentForDisplay() {
        // Leading tab → spaces (visible indent regardless of AppKit tab stops).
        XCTAssertEqual(LogTextLines.displayLines("\tat java.lang.Class.forName"),
                       ["    at java.lang.Class.forName"])
        // Space indentation (pretty-printed JSON) is left untouched.
        XCTAssertEqual(LogTextLines.displayLines("  \"dimensions\": ["),
                       ["  \"dimensions\": ["])
        // Mid-line tab expands to the next 4-column tab stop.
        XCTAssertEqual(LogTextLines.expandingTabs("ab\tc"), "ab  c")   // col2 → 2 spaces to col4
        XCTAssertEqual(LogTextLines.expandingTabs("a\tc"), "a   c")    // col1 → 3 spaces to col4
        // Tab expansion doesn't change the line count vs. count().
        let multi = "header\n\tframe1\n\tframe2"
        XCTAssertEqual(LogTextLines.displayLines(multi).count, LogTextLines.count(multi))
    }

    func testExactlyAtCapNotTruncated() {
        let exact = (0..<LogTextLines.maxPerEntry).map(String.init).joined(separator: "\n")
        XCTAssertFalse(LogTextLines.isTruncated(exact))
        XCTAssertEqual(LogTextLines.displayLines(exact).count, LogTextLines.maxPerEntry)
    }
}

final class DisplayLineMapTests: XCTestCase {
    /// Builds a map from explicit per-log line counts.
    private func map(_ counts: [Int]) -> DisplayLineMap {
        var m = DisplayLineMap()
        for c in counts { m.append(lineCount: c) }
        return m
    }

    func testEmptyMap() {
        let m = DisplayLineMap()
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(m.totalRows, 0)
        XCTAssertEqual(m.logCount, 0)
        XCTAssertEqual(m.locate(row: 0).log, 0)   // safe default, callers gate on totalRows
    }

    func testSingleLineLogsAreOneRowEach() {
        let m = map([1, 1, 1])
        XCTAssertEqual(m.totalRows, 3)
        XCTAssertEqual(m.logCount, 3)
        for r in 0..<3 {
            XCTAssertEqual(m.locate(row: r).log, r)
            XCTAssertEqual(m.locate(row: r).sub, 0)
        }
    }

    func testMultiLineMappingAndRanges() {
        // logs: [1 row][3 rows][1 row][2 rows] → totalRows 7
        let m = map([1, 3, 1, 2])
        XCTAssertEqual(m.totalRows, 7)

        XCTAssertEqual(m.locate(row: 0).log, 0); XCTAssertEqual(m.locate(row: 0).sub, 0)
        XCTAssertEqual(m.locate(row: 1).log, 1); XCTAssertEqual(m.locate(row: 1).sub, 0)
        XCTAssertEqual(m.locate(row: 2).log, 1); XCTAssertEqual(m.locate(row: 2).sub, 1)
        XCTAssertEqual(m.locate(row: 3).log, 1); XCTAssertEqual(m.locate(row: 3).sub, 2)
        XCTAssertEqual(m.locate(row: 4).log, 2); XCTAssertEqual(m.locate(row: 4).sub, 0)
        XCTAssertEqual(m.locate(row: 5).log, 3); XCTAssertEqual(m.locate(row: 5).sub, 0)
        XCTAssertEqual(m.locate(row: 6).log, 3); XCTAssertEqual(m.locate(row: 6).sub, 1)

        XCTAssertEqual(m.firstRow(ofLog: 1), 1)
        XCTAssertEqual(m.firstRow(ofLog: 3), 5)
        XCTAssertEqual(m.rows(ofLog: 1), 1...3)
        XCTAssertEqual(m.rows(ofLog: 3), 5...6)
    }

    func testRemoveFirstRebasesAndReportsRemovedRows() {
        var m = map([1, 3, 1, 2])    // rows: 0 | 1..3 | 4 | 5..6
        let removed = m.removeFirst(2)   // drop the [1] and [3] logs = 4 rows
        XCTAssertEqual(removed, 4)
        XCTAssertEqual(m.logCount, 2)
        XCTAssertEqual(m.totalRows, 3)
        // remaining logs rebased to start at row 0
        XCTAssertEqual(m.firstRow(ofLog: 0), 0)
        XCTAssertEqual(m.rows(ofLog: 0), 0...0)   // was the [1]-row log
        XCTAssertEqual(m.rows(ofLog: 1), 1...2)   // was the [2]-row log
        XCTAssertEqual(m.locate(row: 2).log, 1)
        XCTAssertEqual(m.locate(row: 2).sub, 1)
    }

    func testPrependShiftsExistingAndReportsAddedRows() {
        var m = map([1, 2])              // logs: row 0 | rows 1..2  (total 3)
        let added = m.prepend(lineCounts: [3, 1])   // two older logs above: 3 rows + 1 row
        XCTAssertEqual(added, 4)
        XCTAssertEqual(m.logCount, 4)
        XCTAssertEqual(m.totalRows, 7)
        // prepended logs occupy the top, in order
        XCTAssertEqual(m.rows(ofLog: 0), 0...2)      // first older log (3 rows)
        XCTAssertEqual(m.rows(ofLog: 1), 3...3)      // second older log (1 row)
        // original logs shifted down by the 4 added rows
        XCTAssertEqual(m.rows(ofLog: 2), 4...4)      // was log 0 (1 row)
        XCTAssertEqual(m.rows(ofLog: 3), 5...6)      // was log 1 (2 rows)
        XCTAssertEqual(m.locate(row: 6).log, 3)
        XCTAssertEqual(m.locate(row: 6).sub, 1)
    }

    func testPrependEmptyIsNoOp() {
        var m = map([1, 2])
        XCTAssertEqual(m.prepend(lineCounts: [Int]()), 0)
        XCTAssertEqual(m.logCount, 2)
        XCTAssertEqual(m.totalRows, 3)
    }

    func testRemoveFirstClampsAndAll() {
        var m = map([2, 2])
        XCTAssertEqual(m.removeFirst(0), 0)
        XCTAssertEqual(m.removeFirst(5), 4)   // clamps to logCount, removes all rows
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(m.totalRows, 0)
    }

    func testRemoveAll() {
        var m = map([3, 1, 4])
        m.removeAll()
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(m.totalRows, 0)
    }

    func testRebuildMatchesIncrementalAppend() {
        let counts = [1, 5, 2, 1, 3]
        var rebuilt = DisplayLineMap()
        rebuilt.rebuild(lineCounts: counts)
        XCTAssertEqual(rebuilt, map(counts))
        XCTAssertEqual(rebuilt.totalRows, counts.reduce(0, +))
    }

    func testLocateIsConsistentAcrossEveryRow() {
        let counts = [1, 3, 1, 2, 1, 1, 7, 1]
        let m = map(counts)
        for r in 0..<m.totalRows {
            let loc = m.locate(row: r)
            XCTAssertTrue(m.rows(ofLog: loc.log).contains(r))
            XCTAssertEqual(m.firstRow(ofLog: loc.log) + loc.sub, r)
        }
    }
}
