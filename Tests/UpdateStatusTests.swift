import XCTest
@testable import Jaca

final class UpdateStatusTests: XCTestCase {

    func test_unknown_whenRemoteShaEmpty() {
        XCTAssertEqual(
            UpdateService.decide(remoteSha: "", buildCommit: "abc", behind: 3, subject: "x"),
            .unknown
        )
    }

    func test_upToDate_whenRemoteMatchesInstalledCommit() {
        XCTAssertEqual(
            UpdateService.decide(remoteSha: "abc123", buildCommit: "abc123", behind: 0, subject: ""),
            .upToDate
        )
    }

    func test_upToDate_whenDifferentShaButNothingAhead() {
        // Installed build is ahead/diverged with no upstream commits to pull.
        XCTAssertEqual(
            UpdateService.decide(remoteSha: "remote", buildCommit: "local", behind: 0, subject: "y"),
            .upToDate
        )
    }

    func test_available_whenBehind() {
        XCTAssertEqual(
            UpdateService.decide(remoteSha: "remote", buildCommit: "local", behind: 2, subject: "feat: thing"),
            .available(behind: 2, subject: "feat: thing")
        )
    }

    func test_remoteShaTrimmed() {
        XCTAssertEqual(
            UpdateService.decide(remoteSha: "  abc\n", buildCommit: "abc", behind: 0, subject: ""),
            .upToDate
        )
    }
}
