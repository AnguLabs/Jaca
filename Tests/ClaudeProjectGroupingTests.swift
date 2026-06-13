import XCTest
@testable import Jaca

final class ClaudeProjectGroupingTests: XCTestCase {

    // MARK: - Worktree path detection

    func test_isWorktreePath_andParentExtraction() {
        let wt = "/Users/me/workspace/teya/.claude/worktrees/foamy-drifting-flask"
        XCTAssertTrue(ClaudeProjectGrouping.isWorktreePath(wt))
        XCTAssertEqual(ClaudeProjectGrouping.parentRepoPath(of: wt), "/Users/me/workspace/teya")

        let plain = "/Users/me/workspace/teya"
        XCTAssertFalse(ClaudeProjectGrouping.isWorktreePath(plain))
        XCTAssertNil(ClaudeProjectGrouping.parentRepoPath(of: plain))
    }

    // MARK: - Grouping

    func test_group_nestsWorktreesUnderTheirParentRepo() {
        let entries = [
            ClaudeRawEntry(encodedName: "a", path: "/ws/teya", exists: true, sessionCount: 3, lastActive: nil),
            ClaudeRawEntry(encodedName: "b", path: "/ws/teya/.claude/worktrees/foo",
                           exists: true, sessionCount: 1, lastActive: nil),
            ClaudeRawEntry(encodedName: "c", path: "/ws/teya/.claude/worktrees/bar",
                           exists: true, sessionCount: 0, lastActive: nil),
        ]
        let projects = ClaudeProjectGrouping.group(entries)
        XCTAssertEqual(projects.count, 1)
        let teya = try! XCTUnwrap(projects.first)
        XCTAssertEqual(teya.path, "/ws/teya")
        XCTAssertEqual(teya.sessionCount, 3)
        XCTAssertEqual(teya.worktreeCount, 2)
        // hasClaudeSessions reflects whether the worktree dir itself had session files.
        let foo = try! XCTUnwrap(teya.worktrees.first { $0.path.hasSuffix("foo") })
        let bar = try! XCTUnwrap(teya.worktrees.first { $0.path.hasSuffix("bar") })
        XCTAssertTrue(foo.hasClaudeSessions)
        XCTAssertFalse(bar.hasClaudeSessions)
    }

    func test_group_synthesizesMissingParentForOrphanWorktree() {
        // A worktree whose repo has no Claude project dir of its own.
        let entries = [
            ClaudeRawEntry(encodedName: "b", path: "/ws/jaca/.claude/worktrees/yawning",
                           exists: true, sessionCount: 2, lastActive: nil),
        ]
        let projects = ClaudeProjectGrouping.group(entries)
        XCTAssertEqual(projects.count, 1)
        let jaca = try! XCTUnwrap(projects.first)
        XCTAssertEqual(jaca.path, "/ws/jaca")
        XCTAssertFalse(jaca.exists)          // synthesized placeholder
        XCTAssertEqual(jaca.sessionCount, 0)
        XCTAssertEqual(jaca.worktreeCount, 1)
    }

    // MARK: - Claude-managed flag (drives the "Claude" / "No project" tags)

    func test_isClaudeManaged_reflectsWorktreePath() {
        let managed = ClaudeWorktree(path: "/ws/teya/.claude/worktrees/foo", exists: true,
                                     hasClaudeSessions: false, sessionCount: 0, lastActive: nil)
        XCTAssertTrue(managed.isClaudeManaged)        // under .claude/worktrees, even with no sessions
        let elsewhere = ClaudeWorktree(path: "/ws/teya-wt-foo", exists: true,
                                       hasClaudeSessions: true, sessionCount: 2, lastActive: nil)
        XCTAssertFalse(elsewhere.isClaudeManaged)     // git worktree outside .claude/worktrees
    }

    // MARK: - Active-only filtering

    func test_activeOnly_dropsMissingWorktreesAndEmptyMissingProjects() {
        let live = ClaudeProject(
            path: "/ws/teya", exists: true, sessionCount: 2, lastActive: nil,
            worktrees: [
                ClaudeWorktree(path: "/ws/teya/.claude/worktrees/here", exists: true,
                               hasClaudeSessions: true, sessionCount: 1, lastActive: nil),
                ClaudeWorktree(path: "/ws/teya/.claude/worktrees/gone", exists: false,
                               hasClaudeSessions: true, sessionCount: 1, lastActive: nil),
            ]
        )
        // A project whose folder is gone and whose only worktree is also gone -> dropped.
        let dead = ClaudeProject(
            path: "/ws/dead", exists: false, sessionCount: 0, lastActive: nil,
            worktrees: [ClaudeWorktree(path: "/ws/dead/.claude/worktrees/x", exists: false,
                                       hasClaudeSessions: true, sessionCount: 0, lastActive: nil)]
        )
        // An existing project with no worktrees -> kept.
        let plain = ClaudeProject(path: "/ws/skie", exists: true, sessionCount: 1, lastActive: nil)

        let result = ClaudeProjectGrouping.activeOnly([live, dead, plain])
        XCTAssertEqual(Set(result.map(\.path)), ["/ws/teya", "/ws/skie"])
        let teya = try! XCTUnwrap(result.first { $0.path == "/ws/teya" })
        XCTAssertEqual(teya.worktrees.map(\.path), ["/ws/teya/.claude/worktrees/here"])
    }

    // MARK: - Sorting

    func test_sorted_ordersByRecencyThenName_floatingActiveWorktreesUp() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let older = now.addingTimeInterval(-3600)

        // idleRepo has no own activity but an active worktree -> should sort first.
        let idleRepo = ClaudeProject(
            path: "/ws/idle", exists: true, sessionCount: 0, lastActive: nil,
            worktrees: [ClaudeWorktree(path: "/ws/idle/.claude/worktrees/w", exists: true,
                                       hasClaudeSessions: true, sessionCount: 1, lastActive: now)]
        )
        let oldRepo = ClaudeProject(path: "/ws/old", exists: true, sessionCount: 5, lastActive: older)
        let undated = ClaudeProject(path: "/ws/zeta", exists: true, sessionCount: 0, lastActive: nil)

        let sorted = ClaudeProjectGrouping.sorted([oldRepo, undated, idleRepo])
        XCTAssertEqual(sorted.map(\.path), ["/ws/idle", "/ws/old", "/ws/zeta"])
    }

    // MARK: - cwd extraction

    func test_extractCwd_findsFirstCwdAcrossLines() {
        let jsonl = """
        {"type":"system","sessionId":"x"}
        {"type":"user","cwd":"/Users/me/workspace/teya","gitBranch":"main"}
        {"type":"assistant","cwd":"/Users/me/workspace/teya"}
        """
        XCTAssertEqual(ClaudeSessionProbe.extractCwd(fromJSONL: jsonl), "/Users/me/workspace/teya")
    }

    func test_extractCwd_returnsNilWhenAbsent() {
        let jsonl = """
        {"type":"system","sessionId":"x"}
        {"type":"mode","mode":"default"}
        """
        XCTAssertNil(ClaudeSessionProbe.extractCwd(fromJSONL: jsonl))
    }

    // MARK: - Disk cache round-trip

    func test_cache_roundTripsProjectsAndWorktrees() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jaca-cache-test-\(UUID().uuidString)")
            .appendingPathComponent("claude-projects.json")
        let cache = ClaudeProjectsCache(fileURL: tmp)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        XCTAssertNil(cache.load(), "no file yet -> nil")

        let projects = [
            ClaudeProject(
                path: "/ws/teya", exists: true, sessionCount: 4,
                lastActive: Date(timeIntervalSince1970: 1_000_000), isGitRepo: true,
                worktrees: [ClaudeWorktree(path: "/ws/teya/.claude/worktrees/w", exists: true,
                                           hasClaudeSessions: true, sessionCount: 1,
                                           lastActive: nil, branch: "feature/x", age: "2h ago")]
            ),
            ClaudeProject(path: "/ws/skie", exists: true, sessionCount: 1, lastActive: nil),
        ]
        cache.save(projects)
        XCTAssertEqual(cache.load(), projects)
    }

    // MARK: - Naive decode fallback

    func test_naiveDecode_replacesDashesWithSlashes() {
        XCTAssertEqual(ClaudeProjectsScanner.naiveDecode("-Users-me-workspace-teya"),
                       "/Users/me/workspace/teya")
    }
}
