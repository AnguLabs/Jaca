import XCTest
@testable import Jaca

final class WorktreeParserTests: XCTestCase {
    func test_parsesBranchDetachedPrunableAndSkipsBare() {
        let porcelain = """
        worktree /repo/.bare
        bare

        worktree /repo/main
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /repo/wt-feature
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/feature/checkout-redesign

        worktree /repo/wt-detached
        HEAD 3f9a2c1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        detached

        worktree /repo/wt-gone
        HEAD 4444444444444444444444444444444444444444
        branch refs/heads/old
        prunable gitdir file points to non-existent location

        """
        let entries = WorktreePorcelainParser.parse(porcelain)
        XCTAssertEqual(entries.count, 4) // bare skipped
        XCTAssertEqual(entries[0].path, "/repo/main")
        XCTAssertEqual(entries[0].branch, "main")
        XCTAssertFalse(entries[0].detached)
        XCTAssertFalse(entries[0].prunable)
        XCTAssertEqual(entries[1].branch, "feature/checkout-redesign")
        XCTAssertTrue(entries[2].detached)
        XCTAssertNil(entries[2].branch)
        XCTAssertEqual(entries[2].head, "3f9a2c1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertTrue(entries[3].prunable)
        XCTAssertEqual(entries[3].branch, "old")
    }

    func test_emptyInputYieldsNoEntries() {
        XCTAssertTrue(WorktreePorcelainParser.parse("").isEmpty)
    }
}
