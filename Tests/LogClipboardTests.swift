import XCTest
@testable import Jaca

final class LogClipboardTests: XCTestCase {
    private func line(_ msg: String, tag: String = "Pushy", pid: Int32 = 30802, level: LogLevel = .debug) -> LogLine {
        LogLine(seq: 0, timestamp: Date(timeIntervalSince1970: 0), level: level, tag: tag,
                pid: pid, tid: 0, message: msg, raw: "raw")
    }

    func testMessagesOnlyPrefixesLevelOnePerLine() {
        let lines = [line("Wi-Fi lock acquired", level: .debug),
                     line("Connection lost", level: .debug),
                     line("read-only value.", level: .warn)]
        let text = LogClipboard.text(for: lines, messagesOnly: true)
        XCTAssertEqual(text, "[D] Wi-Fi lock acquired\n[D] Connection lost\n[W] read-only value.")
        XCTAssertFalse(text.contains("Pushy"))      // no tag
        XCTAssertFalse(text.contains("30802"))      // no pid
    }

    func testWithMetadataIncludesTimeLevelTag() {
        let text = LogClipboard.text(for: [line("hello")], messagesOnly: false)
        XCTAssertTrue(text.contains("Pushy (30802)"))
        XCTAssertTrue(text.contains("D"))
        XCTAssertTrue(text.hasSuffix("hello"))
    }

    func testEmptyIsEmpty() {
        XCTAssertEqual(LogClipboard.text(for: [], messagesOnly: true), "")
    }
}
