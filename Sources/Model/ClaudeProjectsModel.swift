import Foundation
import Observation
import AppKit

/// State for the Claude Projects top-level area: every project Claude Code has run in
/// (discovered under `~/.claude/projects`) with its real folder and auto-detected
/// worktrees.
///
/// To feel reactive, the last scan is cached on disk and loaded synchronously at init,
/// so the area renders immediately instead of flashing empty. A fresh scan (which
/// touches the filesystem and git, ~seconds) runs in the background while the cached
/// results stay on screen; interaction is blocked behind a "Refreshing…" message until
/// it finishes. On-appear only triggers a scan when the data is stale, so switching
/// back to the tab within a session is instant.
@Observable
@MainActor
final class ClaudeProjectsModel {
    var projects: [ClaudeProject] = []
    /// A scan is in flight.
    var isRefreshing = false
    /// Project ids whose worktree list is expanded in the UI.
    var expanded: Set<String> = []

    private(set) var lastRefresh: Date?
    private let scanner = ClaudeProjectsScanner()
    private let cache = ClaudeProjectsCache()

    /// How long cached results are considered fresh enough to skip an on-appear rescan.
    private static let autoRefreshTTL: TimeInterval = 30

    init() {
        if let cached = cache.load() { projects = cached }
    }

    var totalWorktrees: Int { projects.reduce(0) { $0 + $1.worktreeCount } }

    /// True only when there's genuinely nothing to show (no cache, never scanned).
    var hasNoData: Bool { projects.isEmpty }

    /// Whether on-appear should kick a rescan: always on the first appear of a session,
    /// then only once the cached data has aged past the TTL.
    var shouldAutoRefresh: Bool {
        guard let lastRefresh else { return true }
        return Date().timeIntervalSince(lastRefresh) > Self.autoRefreshTTL
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let scanner = self.scanner
        let cache = self.cache
        Task { [weak self] in
            let list = await scanner.scan()
            guard let self else { return }
            self.projects = list
            self.isRefreshing = false
            self.lastRefresh = Date()
            cache.save(list)
        }
    }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    /// Opens the folder in Finder (selecting it). No-op if the path is gone.
    func reveal(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
