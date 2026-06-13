import Foundation

/// Where a project came from: auto-discovered under `~/.claude/projects`, or a folder
/// the user added manually (which need not use Claude at all).
enum ProjectSource: String, Codable { case claude, user }

/// A project the app manages: a top-level folder (a git repo or a plain directory),
/// together with its checkouts. For a git repo the checkouts are the main working tree
/// plus any linked worktrees; for a non-git folder there are none (it's informational).
struct Project: Identifiable, Equatable, Codable {
    var path: String
    var exists: Bool
    var isGitRepo: Bool
    var source: ProjectSource
    /// Claude sessions recorded for the project root's own directory.
    var sessionCount: Int
    var lastActive: Date?
    /// `[0]` is the main checkout (`isMain`); the rest are linked worktrees.
    var checkouts: [ProjectCheckout]

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String {
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? path : last
    }
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }

    var worktreeCount: Int { checkouts.filter { !$0.isMain }.count }
    var hasWorktrees: Bool { worktreeCount > 0 }
    /// Expandable when there's anything to act on (the main checkout and/or worktrees).
    var isExpandable: Bool { !checkouts.isEmpty }

    /// Claude-related either by its own sessions, a checkout's sessions, or the
    /// `.claude/worktrees` path convention — drives the "Claude" project badge.
    var isClaudeProject: Bool {
        source == .claude || sessionCount > 0 || checkouts.contains { $0.hasClaudeSessions || $0.isClaudeManaged }
    }

    var totalSizeMB: Int { checkouts.reduce(0) { $0 + $1.sizeMB } }
    var totalCacheMB: Int { checkouts.reduce(0) { $0 + $1.cacheMB } }
    var sizesComputed: Bool { !checkouts.isEmpty && checkouts.allSatisfy(\.sizeComputed) }
    var orphanCount: Int { checkouts.filter(\.orphan).count }

    /// Most recent activity across the root and all checkouts — drives ordering.
    var effectiveLastActive: Date? {
        ([lastActive] + checkouts.map(\.claudeLastActive)).compactMap { $0 }.max()
    }
}

/// One checkout of a project: the main working tree (`isMain`) or a linked git worktree.
/// Carries the git metadata, the auto-detected Claude flags, on-disk sizes, and the
/// transient UI states used while cleaning/removing.
struct ProjectCheckout: Identifiable, Equatable, Codable {
    var path: String
    var isMain: Bool
    var branch: String?
    var base: String?
    var age: String?
    var exists: Bool
    var orphan: Bool = false
    var orphanKind: OrphanKind? = nil

    /// Lives under a repo's `.claude/worktrees/` — i.e. created by Claude Code's
    /// worktree feature, even if its session transcripts were later cleaned up.
    var isClaudeManaged: Bool = false
    var hasClaudeSessions: Bool = false
    var claudeSessionCount: Int = 0
    var claudeLastActive: Date? = nil

    var sizeMB: Int = 0
    var cacheMB: Int = 0
    var sizeComputed: Bool = false

    // Transient UI states.
    var cleaning: Bool = false
    var dropped: Bool = false    // green flash after a cache clear
    var removing: Bool = false   // fade-out before prune

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String {
        if let branch, !branch.isEmpty { return branch }
        if isMain { return "main checkout" }
        return url.lastPathComponent
    }
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

/// A node in the TREE view: a project plus any detected sub-projects nested under it by
/// path containment — e.g. a workspace folder that itself has Claude sessions and
/// contains project folders that do too. In LIST view every node is childless (flat).
struct ProjectNode: Identifiable, Equatable {
    let project: Project
    let children: [ProjectNode]

    var id: String { project.id }
    var hasChildren: Bool { !children.isEmpty }
}

// MARK: - Relative-age formatting (UI)

private let projectRelativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

/// "3h ago" style label for a last-active date; nil when there is none.
func relativeAge(_ date: Date?) -> String? {
    guard let date else { return nil }
    return projectRelativeFormatter.localizedString(for: date, relativeTo: Date())
}
