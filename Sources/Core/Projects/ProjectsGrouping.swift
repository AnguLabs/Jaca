import Foundation

/// Pure helpers for the projects scan — path classification, session-file probing,
/// active-only filtering, and ordering. Kept free of filesystem/git access so they're
/// unit-testable.
enum ProjectsGrouping {
    /// Claude Code creates worktrees under `<repo>/.claude/worktrees/<name>`, so this
    /// marker both identifies a worktree path and locates its parent repo.
    static let worktreeMarker = "/.claude/worktrees/"

    static func isWorktreePath(_ path: String) -> Bool { path.contains(worktreeMarker) }

    /// The parent repo path for a worktree path (everything before the marker), or nil.
    static func parentRepoPath(of path: String) -> String? {
        guard let r = path.range(of: worktreeMarker) else { return nil }
        return String(path[path.startIndex..<r.lowerBound])
    }

    /// Drops anything whose folder no longer exists: a project with a missing root is
    /// removed entirely; otherwise its checkouts are filtered to the ones still on disk
    /// (a `git worktree remove`d tree whose session dir lingers disappears here).
    static func activeOnly(_ projects: [Project]) -> [Project] {
        projects.compactMap { project in
            guard project.exists else { return nil }
            var copy = project
            copy.checkouts = project.checkouts.filter(\.exists)
            return copy
        }
    }

    /// Orders projects (and each project's checkouts) for display: most-recent-first by
    /// effective activity, then name; within a project the main checkout always leads,
    /// then worktrees by recency/name.
    static func sorted(_ projects: [Project]) -> [Project] {
        projects.map { project in
            var copy = project
            copy.checkouts.sort { a, b in
                if a.isMain != b.isMain { return a.isMain }   // main first
                return recency(a.claudeLastActive, a.name, b.claudeLastActive, b.name)
            }
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
