import XCTest
@testable import Jaca

final class ProjectsGroupingTests: XCTestCase {

    // MARK: - Worktree path classification

    func test_isWorktreePath_andParentExtraction() {
        let wt = "/Users/me/workspace/teya/.claude/worktrees/foamy-drifting-flask"
        XCTAssertTrue(ProjectsGrouping.isWorktreePath(wt))
        XCTAssertEqual(ProjectsGrouping.parentRepoPath(of: wt), "/Users/me/workspace/teya")

        let plain = "/Users/me/workspace/teya"
        XCTAssertFalse(ProjectsGrouping.isWorktreePath(plain))
        XCTAssertNil(ProjectsGrouping.parentRepoPath(of: plain))
    }

    func test_checkout_isClaudeManaged_reflectsWorktreePath() {
        XCTAssertTrue(ProjectsGrouping.isWorktreePath("/ws/teya/.claude/worktrees/foo"))
        XCTAssertFalse(ProjectsGrouping.isWorktreePath("/ws/teya-wt-foo"))
    }

    // MARK: - Active-only filtering

    func test_activeOnly_dropsMissingCheckoutsAndMissingProjects() {
        let live = Project(
            path: "/ws/teya", exists: true, isGitRepo: true, source: .claude,
            sessionCount: 2, lastActive: nil,
            checkouts: [
                checkout("/ws/teya", isMain: true, exists: true),
                checkout("/ws/teya/.claude/worktrees/here", isMain: false, exists: true),
                checkout("/ws/teya/.claude/worktrees/gone", isMain: false, exists: false),
            ]
        )
        let deadRoot = Project(
            path: "/ws/dead", exists: false, isGitRepo: true, source: .user,
            sessionCount: 0, lastActive: nil,
            checkouts: [checkout("/ws/dead", isMain: true, exists: false)]
        )
        let nonGit = Project(
            path: "/ws/notes", exists: true, isGitRepo: false, source: .claude,
            sessionCount: 5, lastActive: nil, checkouts: []
        )

        let result = ProjectsGrouping.activeOnly([live, deadRoot, nonGit])
        XCTAssertEqual(Set(result.map(\.path)), ["/ws/teya", "/ws/notes"])  // dead root dropped
        let teya = try! XCTUnwrap(result.first { $0.path == "/ws/teya" })
        XCTAssertEqual(teya.checkouts.map(\.path), ["/ws/teya", "/ws/teya/.claude/worktrees/here"])
        XCTAssertEqual(teya.worktreeCount, 1)
    }

    // MARK: - Sorting (main first; projects by recency)

    func test_sorted_putsMainCheckoutFirstAndProjectsByRecency() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let older = now.addingTimeInterval(-3600)

        // Idle root, active worktree -> floats to the top via effectiveLastActive.
        let idle = Project(
            path: "/ws/idle", exists: true, isGitRepo: true, source: .claude,
            sessionCount: 0, lastActive: nil,
            checkouts: [
                checkout("/ws/idle/.claude/worktrees/w", isMain: false, claudeLast: now),
                checkout("/ws/idle", isMain: true),
            ]
        )
        let old = Project(path: "/ws/old", exists: true, isGitRepo: true, source: .claude,
                          sessionCount: 1, lastActive: older, checkouts: [])

        let sorted = ProjectsGrouping.sorted([old, idle])
        XCTAssertEqual(sorted.map(\.path), ["/ws/idle", "/ws/old"])
        XCTAssertTrue(sorted[0].checkouts.first?.isMain == true)  // main reordered to front
    }

    // MARK: - cwd extraction

    func test_extractCwd_findsFirstCwdAcrossLines() {
        let jsonl = """
        {"type":"system","sessionId":"x"}
        {"type":"user","cwd":"/Users/me/workspace/teya","gitBranch":"main"}
        """
        XCTAssertEqual(ClaudeSessionProbe.extractCwd(fromJSONL: jsonl), "/Users/me/workspace/teya")
    }

    func test_extractCwd_returnsNilWhenAbsent() {
        XCTAssertNil(ClaudeSessionProbe.extractCwd(fromJSONL: #"{"type":"mode","mode":"default"}"#))
    }

    // MARK: - Naive decode fallback

    func test_naiveDecode_replacesDashesWithSlashes() {
        XCTAssertEqual(ProjectsScanner.naiveDecode("-Users-me-workspace-teya"),
                       "/Users/me/workspace/teya")
    }

    // MARK: - Disk cache round-trip (incl. sizes + worktrees)

    func test_cache_roundTripsProjectsAndCheckouts() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jaca-cache-test-\(UUID().uuidString)")
            .appendingPathComponent("projects.json")
        let cache = ProjectsCache(fileURL: tmp)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        XCTAssertNil(cache.load())

        var main = checkout("/ws/teya", isMain: true, exists: true)
        main.sizeMB = 1200; main.cacheMB = 800; main.sizeComputed = true
        let wt = checkout("/ws/teya/.claude/worktrees/foo", isMain: false, exists: true)
        let projects = [Project(
            path: "/ws/teya", exists: true, isGitRepo: true, source: .claude,
            sessionCount: 3, lastActive: Date(timeIntervalSince1970: 1_000_000),
            checkouts: [main, wt]
        )]
        cache.save(projects)
        XCTAssertEqual(cache.load(), projects)
    }

    // MARK: - Helpers

    private func checkout(_ path: String, isMain: Bool, exists: Bool = true,
                          claudeLast: Date? = nil) -> ProjectCheckout {
        ProjectCheckout(
            path: path, isMain: isMain, branch: isMain ? nil : (path as NSString).lastPathComponent,
            base: nil, age: nil, exists: exists,
            isClaudeManaged: ProjectsGrouping.isWorktreePath(path),
            hasClaudeSessions: claudeLast != nil, claudeSessionCount: claudeLast != nil ? 1 : 0,
            claudeLastActive: claudeLast
        )
    }
}
