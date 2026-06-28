import XCTest
@testable import Jaca

final class ProjectsGroupingTests: XCTestCase {

    // MARK: - Worktree path classification

    func test_isWorktreePath_andParentExtraction() {
        let wt = "/Users/me/workspace/myapp/.claude/worktrees/foamy-drifting-flask"
        XCTAssertTrue(ProjectsGrouping.isWorktreePath(wt))
        XCTAssertEqual(ProjectsGrouping.parentRepoPath(of: wt), "/Users/me/workspace/myapp")

        let plain = "/Users/me/workspace/myapp"
        XCTAssertFalse(ProjectsGrouping.isWorktreePath(plain))
        XCTAssertNil(ProjectsGrouping.parentRepoPath(of: plain))
    }

    func test_checkout_isClaudeManaged_reflectsWorktreePath() {
        XCTAssertTrue(ProjectsGrouping.isWorktreePath("/ws/myapp/.claude/worktrees/foo"))
        XCTAssertFalse(ProjectsGrouping.isWorktreePath("/ws/myapp-wt-foo"))
    }

    // MARK: - Active-only filtering

    func test_activeOnly_dropsMissingCheckoutsAndMissingProjects() {
        let live = Project(
            path: "/ws/myapp", exists: true, isGitRepo: true, source: .claude,
            sessionCount: 2, lastActive: nil,
            checkouts: [
                checkout("/ws/myapp", isMain: true, exists: true),
                checkout("/ws/myapp/.claude/worktrees/here", isMain: false, exists: true),
                checkout("/ws/myapp/.claude/worktrees/gone", isMain: false, exists: false),
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
        XCTAssertEqual(Set(result.map(\.path)), ["/ws/myapp", "/ws/notes"])  // dead root dropped
        let myapp = try! XCTUnwrap(result.first { $0.path == "/ws/myapp" })
        XCTAssertEqual(myapp.checkouts.map(\.path), ["/ws/myapp", "/ws/myapp/.claude/worktrees/here"])
        XCTAssertEqual(myapp.worktreeCount, 1)
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

    func test_sorted_ordersWorktreesByLastModifiedNewestFirst() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // Worktrees with NO Claude activity, only git commit dates — these previously
        // fell back to alphabetical order; they must now sort newest-commit first.
        let project = Project(
            path: "/ws/app", exists: true, isGitRepo: true, source: .claude,
            sessionCount: 0, lastActive: nil,
            checkouts: [
                checkout("/ws/app/.claude/worktrees/alpha", isMain: false, lastCommit: t0.addingTimeInterval(-3600)),
                checkout("/ws/app/.claude/worktrees/zeta", isMain: false, lastCommit: t0),  // newest
                checkout("/ws/app", isMain: true, lastCommit: t0.addingTimeInterval(-9000)),
                checkout("/ws/app/.claude/worktrees/mid", isMain: false, lastCommit: t0.addingTimeInterval(-1800)),
            ]
        )
        let sorted = ProjectsGrouping.sorted([project])[0].checkouts.map(\.name)
        // Main pinned first, then worktrees newest-commit → oldest (zeta, mid, alpha).
        XCTAssertEqual(sorted, ["main checkout", "zeta", "mid", "alpha"])
    }

    func test_lastModified_usesCommitDateAndIgnoresNoisyClaudeMtime() {
        let commit = Date(timeIntervalSince1970: 1_000_000)
        let claudeNewer = commit.addingTimeInterval(600)  // bulk-touched .jsonl, not real activity
        let committed = checkout("/ws/app/.claude/worktrees/w", isMain: false,
                                 claudeLast: claudeNewer, lastCommit: commit)
        XCTAssertEqual(committed.lastModified, commit)  // the displayed commit date wins

        // No commit (e.g. orphaned worktree) → fall back to Claude activity.
        let orphan = checkout("/ws/app/.claude/worktrees/o", isMain: false,
                              claudeLast: claudeNewer, lastCommit: nil)
        XCTAssertEqual(orphan.lastModified, claudeNewer)
    }

    // MARK: - Migration: old cache JSON without the lastCommit key

    func test_decode_oldCheckoutWithoutLastCommit_defaultsToNil() throws {
        // A checkout encoded before `lastCommit` existed — must decode, not fail/wipe.
        let json = #"{"path":"/ws/app","isMain":true,"exists":true,"orphan":false,"isClaudeManaged":false,"hasClaudeSessions":false,"claudeSessionCount":0,"sizeMB":0,"cacheMB":0,"sizeComputed":false,"cleaning":false,"dropped":false,"removing":false}"#
        let c = try JSONDecoder().decode(ProjectCheckout.self, from: Data(json.utf8))
        XCTAssertNil(c.lastCommit)
        XCTAssertEqual(c.path, "/ws/app")
    }

    // MARK: - Tree nesting

    func test_tree_nestsSubProjectsUnderContainer() {
        let workspace = project("/ws", git: false)
        let myapp = project("/ws/myapp", git: true)
        let jaca = project("/ws/jaca", git: true)
        let outside = project("/other/repo", git: true)

        let roots = ProjectsGrouping.tree([myapp, workspace, jaca, outside])
        // Two roots: the container and the unrelated repo.
        XCTAssertEqual(Set(roots.map(\.id)), ["/ws", "/other/repo"])
        let ws = try! XCTUnwrap(roots.first { $0.id == "/ws" })
        XCTAssertEqual(Set(ws.children.map(\.id)), ["/ws/myapp", "/ws/jaca"])
        XCTAssertTrue(ws.hasChildren)
        // The unrelated repo is a childless root.
        let other = try! XCTUnwrap(roots.first { $0.id == "/other/repo" })
        XCTAssertFalse(other.hasChildren)
    }

    func test_tree_withoutContainment_isFlatLikeList() {
        let a = project("/ws/myapp", git: true)
        let b = project("/ws/jaca", git: true)   // siblings, no project at /ws
        let tree = ProjectsGrouping.tree([a, b])
        XCTAssertEqual(tree.count, 2)
        XCTAssertTrue(tree.allSatisfy { !$0.hasChildren })
        XCTAssertEqual(Set(tree.map(\.id)), Set(ProjectsGrouping.flat([a, b]).map(\.id)))
    }

    func test_tree_nestsByNearestAncestor() {
        let root = project("/ws", git: false)
        let group = project("/ws/group", git: false)
        let leaf = project("/ws/group/app", git: true)
        let roots = ProjectsGrouping.tree([leaf, root, group])
        let ws = try! XCTUnwrap(roots.first { $0.id == "/ws" })
        XCTAssertEqual(ws.children.map(\.id), ["/ws/group"])           // group under ws
        XCTAssertEqual(ws.children.first?.children.map(\.id), ["/ws/group/app"])  // app under group, not ws
    }

    // MARK: - cwd extraction

    func test_extractCwd_findsFirstCwdAcrossLines() {
        let jsonl = """
        {"type":"system","sessionId":"x"}
        {"type":"user","cwd":"/Users/me/workspace/myapp","gitBranch":"main"}
        """
        XCTAssertEqual(ClaudeSessionProbe.extractCwd(fromJSONL: jsonl), "/Users/me/workspace/myapp")
    }

    func test_extractCwd_returnsNilWhenAbsent() {
        XCTAssertNil(ClaudeSessionProbe.extractCwd(fromJSONL: #"{"type":"mode","mode":"default"}"#))
    }

    // MARK: - Naive decode fallback

    func test_naiveDecode_replacesDashesWithSlashes() {
        XCTAssertEqual(ProjectsScanner.naiveDecode("-Users-me-workspace-myapp"),
                       "/Users/me/workspace/myapp")
    }

    // MARK: - Disk cache round-trip (incl. sizes + worktrees)

    func test_cache_roundTripsProjectsAndCheckouts() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jaca-cache-test-\(UUID().uuidString)")
            .appendingPathComponent("projects.json")
        let cache = ProjectsCache(fileURL: tmp)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        XCTAssertNil(cache.load())

        var main = checkout("/ws/myapp", isMain: true, exists: true)
        main.sizeMB = 1200; main.cacheMB = 800; main.sizeComputed = true
        let wt = checkout("/ws/myapp/.claude/worktrees/foo", isMain: false, exists: true)
        let projects = [Project(
            path: "/ws/myapp", exists: true, isGitRepo: true, source: .claude,
            sessionCount: 3, lastActive: Date(timeIntervalSince1970: 1_000_000),
            checkouts: [main, wt]
        )]
        cache.save(projects)
        XCTAssertEqual(cache.load(), projects)
    }

    // MARK: - Helpers

    private func project(_ path: String, git: Bool, last: Date? = nil) -> Project {
        Project(path: path, exists: true, isGitRepo: git, source: .claude,
                sessionCount: 1, lastActive: last, checkouts: [])
    }

    private func checkout(_ path: String, isMain: Bool, exists: Bool = true,
                          claudeLast: Date? = nil, lastCommit: Date? = nil) -> ProjectCheckout {
        ProjectCheckout(
            path: path, isMain: isMain, branch: isMain ? nil : (path as NSString).lastPathComponent,
            base: nil, age: nil, exists: exists,
            isClaudeManaged: ProjectsGrouping.isWorktreePath(path),
            hasClaudeSessions: claudeLast != nil, claudeSessionCount: claudeLast != nil ? 1 : 0,
            claudeLastActive: claudeLast, lastCommit: lastCommit
        )
    }
}
