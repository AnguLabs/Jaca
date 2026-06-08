import XCTest
@testable import Jaca

final class PackageFilterPIDTests: XCTestCase {
    /// The bug: when the app crashes, pidof returns empty; setting the filter's PID
    /// set to empty hid EVERY line. Accumulation must never clear on death.
    func testAccumulatePIDsNeverClearsWhenAppDies() {
        var pids: Set<Int32> = []
        pids = LogSession.accumulatePIDs(pids, with: [100])   // app starts
        XCTAssertEqual(pids, [100])
        pids = LogSession.accumulatePIDs(pids, with: [])      // crash → keep, don't hide logs
        XCTAssertEqual(pids, [100])
        pids = LogSession.accumulatePIDs(pids, with: [200])   // reinstall → new pid added
        XCTAssertEqual(pids, [100, 200])
        pids = LogSession.accumulatePIDs(pids, with: [])      // dies again → keep both
        XCTAssertEqual(pids, [100, 200])
    }

    func testEmptyPidSetMatchesNothing_documentsTheBug() {
        var filter = LogFilter()
        filter.pids = []                          // the broken state we now avoid
        let line = LogLine(seq: 0, timestamp: Date(), level: .info, tag: "T",
                           pid: 100, tid: 0, message: "hi", raw: "hi")
        XCTAssertFalse(filter.matches(line, regex: nil), "empty pid set hides everything")

        filter.pids = [100]                       // accumulated PID keeps the app's logs
        XCTAssertTrue(filter.matches(line, regex: nil))
    }
}
