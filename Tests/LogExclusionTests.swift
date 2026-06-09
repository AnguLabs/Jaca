import XCTest
@testable import Jaca

final class LogExclusionTests: XCTestCase {
    private func line(_ msg: String, tag: String = "T") -> LogLine {
        LogLine(seq: 0, timestamp: Date(), level: .info, tag: tag, pid: 1, tid: 0, message: msg, raw: msg)
    }

    func testPrefixAndContainsMatching() {
        let prefix = LogExcludeRule(value: "setRequestedFrameRate", mode: .prefix)
        XCTAssertTrue(prefix.excludes("setRequestedFrameRate(60.0)"))
        XCTAssertFalse(prefix.excludes("calling setRequestedFrameRate"))   // not at the start

        let contains = LogExcludeRule(value: "FrameRate", mode: .contains)
        XCTAssertTrue(contains.excludes("calling setRequestedFrameRate"))
        XCTAssertFalse(LogExcludeRule(value: "", mode: .contains).excludes("anything"))  // empty = no-op
    }

    func testFilterHidesExcludedButKeepsOthers() {
        var f = LogFilter()
        f.exclusions = [LogExcludeRule(value: "setRequestedFrameRate", mode: .prefix)]
        XCTAssertFalse(f.matches(line("setRequestedFrameRate(60.0)"), regex: nil))
        XCTAssertTrue(f.matches(line("user tapped checkout"), regex: nil))
    }

    func testMarkersAreNeverExcluded() {
        var f = LogFilter()
        f.exclusions = [LogExcludeRule(value: "CRASH", mode: .contains)]
        XCTAssertTrue(f.matches(.marker("💥 CRASH"), regex: nil))   // markers bypass all filters
    }

    @MainActor
    func testDefaultSeedExcludesSetRequestedFrameRate() {
        XCTAssertTrue(LogExclusionStore.defaults.contains {
            $0.value == "setRequestedFrameRate" && $0.mode == .prefix
        })
    }

    func testRuleRoundTripsThroughJSON() throws {
        let rules = [LogExcludeRule(value: "setRequestedFrameRate", mode: .prefix),
                     LogExcludeRule(value: "Choreographer", mode: .contains)]
        let data = try JSONEncoder().encode(rules)
        let restored = try JSONDecoder().decode([LogExcludeRule].self, from: data)
        XCTAssertEqual(restored, rules)
    }
}
