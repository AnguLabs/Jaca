import Foundation
import Observation
import AppKit

/// A transient toast shown over the Projects area.
struct ProjectsToast: Equatable { var message: String; var systemFallback: String }

/// How the Projects list is laid out: a flat list, or a tree that nests detected
/// sub-projects under their container folder.
enum ProjectsViewMode: String, CaseIterable { case tree, list }

/// State for the unified Projects area — the merge of the old Worktrees and Claude
/// Projects areas. It auto-discovers projects Claude Code has run in (and their
/// worktrees), lets the user add arbitrary folders, and offers per-checkout disk-cache
/// cleanup + worktree removal.
///
/// Reactivity: the last scan (with sizes) is cached on disk and loaded synchronously at
/// init, so the area renders instantly. The first scan of a cold start blocks behind a
/// loader; afterwards scans run in the background. `~/.claude/projects` and each repo's
/// `.git/worktrees` are watched so new/removed worktrees refresh the list automatically,
/// and on-appear only rescans when the data is stale.
@Observable
@MainActor
final class ProjectsModel {
    var projects: [Project] = []
    var isRefreshing = false
    private(set) var hasCompletedScan = false
    var expanded: Set<String> = []
    var toast: ProjectsToast?

    /// List vs tree layout; persisted, defaults to tree.
    var viewMode: ProjectsViewMode {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: Self.viewModeKey) }
    }

    private(set) var lastRefresh: Date?
    private var userFolders: [String]
    private let scanner = ProjectsScanner()
    private let cache = ProjectsCache()
    private let git = GitService()
    private let cleaner = CacheCleaner()
    private var watchers: [FolderWatcher] = []
    private var toastTask: Task<Void, Never>?
    private var scanToken = 0

    private static let autoRefreshTTL: TimeInterval = 30
    private static let userFoldersKey = "jaca.projectFolders"
    private static let legacyWorktreeKey = "jaca.worktreesFolder"
    private static let viewModeKey = "jaca.projectsViewMode"

    init() {
        userFolders = Self.loadUserFolders()
        viewMode = UserDefaults.standard.string(forKey: Self.viewModeKey)
            .flatMap(ProjectsViewMode.init(rawValue:)) ?? .tree
        if let cached = cache.load() { projects = cached }
        startWatching()
    }

    // MARK: - Derived

    var totalProjects: Int { projects.count }
    var totalWorktrees: Int { projects.reduce(0) { $0 + $1.worktreeCount } }
    var hasNoData: Bool { projects.isEmpty }

    /// The projects laid out per the current view mode (tree nests sub-projects).
    var nodes: [ProjectNode] {
        viewMode == .tree ? ProjectsGrouping.tree(projects) : ProjectsGrouping.flat(projects)
    }
    /// Block the UI with a loader only on a cold first scan (no cache to show).
    var isFirstLoad: Bool { projects.isEmpty && isRefreshing && !hasCompletedScan }

    var shouldAutoRefresh: Bool {
        guard let lastRefresh else { return true }
        return Date().timeIntervalSince(lastRefresh) > Self.autoRefreshTTL
    }

    // MARK: - Scanning

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        scanToken &+= 1
        let token = scanToken
        let scanner = self.scanner
        let folders = userFolders
        Task { [weak self] in
            let scanned = await scanner.scan(userFolders: folders)
            guard let self, token == self.scanToken else { return }
            // Carry over already-computed sizes so a refresh doesn't flash "—".
            let previous = self.checkoutIndex(self.projects)
            self.projects = scanned.map { project in
                var p = project
                p.checkouts = p.checkouts.map { c in
                    guard let old = previous[c.path], old.sizeComputed else { return c }
                    var merged = c
                    merged.sizeMB = old.sizeMB
                    merged.cacheMB = old.cacheMB
                    merged.sizeComputed = true
                    return merged
                }
                return p
            }
            self.isRefreshing = false
            self.hasCompletedScan = true
            self.lastRefresh = Date()
            self.startWatching()
            self.computeSizes(token: token)
            self.saveCache()
        }
    }

    /// Computes disk usage for every git checkout in the background, patching rows as
    /// `du` completes, then re-saves the cache.
    private func computeSizes(token: Int) {
        let work: [(pid: String, cid: String, url: URL)] = projects
            .filter(\.isGitRepo)
            .flatMap { p in p.checkouts.map { (p.id, $0.id, $0.url) } }
        guard !work.isEmpty else { return }
        let git = self.git
        Task { [weak self] in
            await withTaskGroup(of: (String, String, Int, Int).self) { group in
                for item in work {
                    group.addTask {
                        let u = await git.diskUsage(of: item.url)
                        return (item.pid, item.cid, u.sizeMB, u.cacheMB)
                    }
                }
                for await (pid, cid, size, cacheMB) in group {
                    guard let self, token == self.scanToken else { continue }
                    self.patchCheckout(pid, cid) { $0.sizeMB = size; $0.cacheMB = cacheMB; $0.sizeComputed = true }
                }
            }
            guard let self, token == self.scanToken else { return }
            self.saveCache()
        }
    }

    private func checkoutIndex(_ projects: [Project]) -> [String: ProjectCheckout] {
        var map: [String: ProjectCheckout] = [:]
        for p in projects { for c in p.checkouts { map[c.path] = c } }
        return map
    }

    private func saveCache() { cache.save(projects) }

    // MARK: - Folder watching

    /// Watches `~/.claude/projects` (new Claude projects/worktrees) plus each git repo's
    /// `.git/worktrees` (any `git worktree add/remove`), refreshing in the background on
    /// change. Rebuilt after every scan since the project set changes.
    private func startWatching() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()

        let onChange: () -> Void = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }

        let claudeProjects = scanner.claudeHome.appendingPathComponent("projects")
        if let w = FolderWatcher(url: claudeProjects, onChange: onChange) { watchers.append(w) }

        for project in projects where project.isGitRepo {
            let wtDir = project.url.appendingPathComponent(".git/worktrees")
            if FileManager.default.fileExists(atPath: wtDir.path),
               let w = FolderWatcher(url: wtDir, onChange: onChange) {
                watchers.append(w)
            }
        }
    }

    // MARK: - Expansion

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
    func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    // MARK: - User folders

    func addFolder() {
        guard let url = ProjectsOpen.pickFolder() else { return }
        let path = url.path
        guard !userFolders.contains(path) else { flash("Already added"); return }
        userFolders.append(path)
        Self.saveUserFolders(userFolders)
        flash("Added \(url.lastPathComponent)")
        refresh()
    }

    /// Removes a manually-added project from the list (does not touch the folder on disk).
    func removeUserProject(_ id: String) {
        guard let project = projects.first(where: { $0.id == id }), project.source == .user else { return }
        userFolders.removeAll { $0 == id }
        Self.saveUserFolders(userFolders)
        projects.removeAll { $0.id == id }
        saveCache()
        flash("Removed \(project.name)", fallback: "eraser")
    }

    private static func loadUserFolders() -> [String] {
        var folders = UserDefaults.standard.stringArray(forKey: userFoldersKey) ?? []
        // Migrate the old single Worktrees folder into the user-folder list once.
        if let legacy = UserDefaults.standard.url(forKey: legacyWorktreeKey)?.path,
           !folders.contains(legacy) {
            folders.append(legacy)
            UserDefaults.standard.set(folders, forKey: userFoldersKey)
            UserDefaults.standard.removeObject(forKey: legacyWorktreeKey)
        }
        return folders
    }

    private static func saveUserFolders(_ folders: [String]) {
        UserDefaults.standard.set(folders, forKey: userFoldersKey)
    }

    // MARK: - Cache cleaning

    /// Clears build caches for a checkout (`./gradlew clean` + matching iOS DerivedData).
    func clearCache(project pid: String, checkout cid: String) {
        guard let c = checkout(pid, cid), !c.cleaning else { return }
        let oldSize = c.sizeMB
        let name = c.name
        let path = c.url
        let cleaner = self.cleaner
        patchCheckout(pid, cid) { $0.cleaning = true }
        Task { [weak self] in
            let result = await cleaner.clearCache(worktree: path)
            guard let self else { return }
            let freed = max(0, oldSize - result.newSizeMB) + result.derivedFreedMB
            self.patchCheckout(pid, cid) {
                $0.cleaning = false
                $0.sizeMB = result.newSizeMB
                $0.sizeComputed = true
                $0.dropped = true
            }
            if let error = result.error {
                self.flash("Clean failed · \(error.prefix(50))", fallback: "sparkles")
            } else {
                self.flash("Freed \(formatSize(freed)) · \(name)", fallback: "sparkles")
            }
            self.saveCache()
            try? await Task.sleep(for: .milliseconds(1400))
            self.patchCheckout(pid, cid) { $0.dropped = false }
        }
    }

    // MARK: - Worktree removal

    /// Removes a linked worktree (`git worktree remove --force`). The main checkout
    /// can't be removed.
    func deleteWorktree(project pid: String, checkout cid: String) {
        guard let project = projects.first(where: { $0.id == pid }),
              let c = checkout(pid, cid), !c.isMain else { return }
        let path = c.url
        let name = c.name
        let git = self.git
        Task { [weak self] in
            guard let self else { return }
            let result = await git.removeWorktree(at: path, repo: project.url)
            guard result.ok else {
                let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                self.flash(msg.isEmpty ? "Couldn't remove worktree" : msg, fallback: "eraser")
                return
            }
            self.patchCheckout(pid, cid) { $0.removing = true }
            try? await Task.sleep(for: .milliseconds(280))
            self.removeCheckout(pid, cid)
            self.saveCache()
            self.flash("Deleted \(name)", fallback: "eraser")
        }
    }

    // MARK: - Reveal

    func reveal(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Toast

    func flash(_ message: String, fallback: String = "checkmark") {
        toastTask?.cancel()
        toast = ProjectsToast(message: message, systemFallback: fallback)
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2600))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: - Mutation helpers

    private func checkout(_ pid: String, _ cid: String) -> ProjectCheckout? {
        projects.first { $0.id == pid }?.checkouts.first { $0.id == cid }
    }

    private func patchCheckout(_ pid: String, _ cid: String, _ mutate: (inout ProjectCheckout) -> Void) {
        guard let pi = projects.firstIndex(where: { $0.id == pid }),
              let ci = projects[pi].checkouts.firstIndex(where: { $0.id == cid }) else { return }
        mutate(&projects[pi].checkouts[ci])
    }

    private func removeCheckout(_ pid: String, _ cid: String) {
        guard let pi = projects.firstIndex(where: { $0.id == pid }) else { return }
        projects[pi].checkouts.removeAll { $0.id == cid }
    }
}
