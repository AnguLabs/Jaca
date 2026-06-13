import Foundation

/// Pure helpers for turning decoded `~/.claude/projects` entries into a project tree.
/// Kept free of any filesystem/git access so the grouping logic is unit-testable.
enum ClaudeProjectGrouping {
    /// Claude Code creates worktrees under `<repo>/.claude/worktrees/<name>`, so this
    /// marker both identifies a worktree path and locates its parent repo.
    static let worktreeMarker = "/.claude/worktrees/"

    static func isWorktreePath(_ path: String) -> Bool { path.contains(worktreeMarker) }

    /// The parent repo path for a worktree path (everything before the marker), or nil.
    static func parentRepoPath(of path: String) -> String? {
        guard let r = path.range(of: worktreeMarker) else { return nil }
        return String(path[path.startIndex..<r.lowerBound])
    }

    /// Groups raw entries into projects with their worktrees nested. A worktree entry
    /// is attached to the project at its parent-repo path; if no root entry exists for
    /// that parent, a non-existent placeholder project is synthesized so the worktree
    /// is never orphaned. (The scanner pre-seeds real parents with correct `exists`.)
    static func group(_ entries: [ClaudeRawEntry]) -> [ClaudeProject] {
        var projects: [String: ClaudeProject] = [:]

        for e in entries where !isWorktreePath(e.path) {
            projects[e.path] = ClaudeProject(
                path: e.path, exists: e.exists,
                sessionCount: e.sessionCount, lastActive: e.lastActive
            )
        }

        for e in entries where isWorktreePath(e.path) {
            guard let parent = parentRepoPath(of: e.path) else { continue }
            if projects[parent] == nil {
                projects[parent] = ClaudeProject(path: parent, exists: false, sessionCount: 0, lastActive: nil)
            }
            projects[parent]?.worktrees.append(
                ClaudeWorktree(
                    path: e.path, exists: e.exists,
                    hasClaudeSessions: e.sessionCount > 0,
                    sessionCount: e.sessionCount, lastActive: e.lastActive
                )
            )
        }

        return Array(projects.values)
    }

    /// Drops anything whose folder no longer exists on disk: stale worktrees (e.g. a
    /// `git worktree remove`d tree whose Claude session dir lingers) are filtered out,
    /// and a project is dropped only if its own folder is gone *and* it has no surviving
    /// worktrees — so the list shows only active checkouts.
    static func activeOnly(_ projects: [ClaudeProject]) -> [ClaudeProject] {
        projects.compactMap { project in
            var copy = project
            copy.worktrees = project.worktrees.filter(\.exists)
            guard copy.exists || !copy.worktrees.isEmpty else { return nil }
            return copy
        }
    }

    /// Orders projects (and each project's worktrees) by recency, then name — the order
    /// the UI renders. Projects sort by `effectiveLastActive` so an idle repo with an
    /// active worktree still floats up.
    static func sorted(_ projects: [ClaudeProject]) -> [ClaudeProject] {
        projects.map { project in
            var copy = project
            copy.worktrees.sort { recency($0.lastActive, $0.name, $1.lastActive, $1.name) }
            return copy
        }
        .sorted { recency($0.effectiveLastActive, $0.name, $1.effectiveLastActive, $1.name) }
    }

    /// More-recent-first; entries with no date sink below dated ones; ties break by name.
    private static func recency(_ ad: Date?, _ an: String, _ bd: Date?, _ bn: String) -> Bool {
        switch (ad, bd) {
        case let (x?, y?): return x == y ? an < bn : x > y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return an < bn
        }
    }
}

/// Pulls the working directory out of a session JSONL chunk. Each line is a JSON
/// object; user/assistant lines carry a `cwd`, which is the only loss-free way to
/// recover a project's real path from its flattened directory name.
enum ClaudeSessionProbe {
    private struct CwdProbe: Decodable { let cwd: String? }

    static func extractCwd(fromJSONL text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"cwd\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let probe = try? JSONDecoder().decode(CwdProbe.self, from: data),
                  let cwd = probe.cwd, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }
}
