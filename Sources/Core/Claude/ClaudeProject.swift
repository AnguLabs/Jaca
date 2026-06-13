import Foundation

/// A raw `~/.claude/projects/<encoded>` entry after its real path has been decoded.
/// `isSynthetic` marks a parent repo inferred from a worktree path that has no
/// Claude project directory of its own (so no sessions, no encoded dir).
struct ClaudeRawEntry: Equatable {
    var encodedName: String
    var path: String
    var exists: Bool
    var sessionCount: Int
    var lastActive: Date?
    var isSynthetic: Bool = false
}

/// A detected Claude Code project: a folder Claude Code has run in (or the parent of
/// such a folder), together with any worktrees that live under it.
struct ClaudeProject: Identifiable, Equatable, Codable {
    var path: String
    var exists: Bool
    var sessionCount: Int
    var lastActive: Date?
    var isGitRepo: Bool = false
    var worktrees: [ClaudeWorktree] = []

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String {
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? path : last
    }
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
    var worktreeCount: Int { worktrees.count }

    /// Most recent activity across the project's own sessions and all its worktrees —
    /// drives ordering, since a repo's own dir may be idle while its worktrees are hot.
    var effectiveLastActive: Date? {
        ([lastActive] + worktrees.map(\.lastActive)).compactMap { $0 }.max()
    }
}

/// A worktree belonging to a `ClaudeProject`. It may be sourced from a Claude session
/// directory, from `git worktree list`, or matched in both.
struct ClaudeWorktree: Identifiable, Equatable, Codable {
    var path: String
    var exists: Bool
    var hasClaudeSessions: Bool
    var sessionCount: Int
    var lastActive: Date?
    var branch: String? = nil
    var age: String? = nil

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String {
        if let branch, !branch.isEmpty { return branch }
        return url.lastPathComponent
    }
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

// MARK: - Relative-age formatting (UI)

private let claudeRelativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

/// "3h ago" style label for a last-active date; nil when there is none.
func relativeAge(_ date: Date?) -> String? {
    guard let date else { return nil }
    return claudeRelativeFormatter.localizedString(for: date, relativeTo: Date())
}
