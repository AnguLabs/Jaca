import Foundation
import Observation

/// Phase of a worktrees tab's scan lifecycle.
enum WorktreesPhase { case empty, scanning, ready }

/// A transient toast shown over the worktrees view.
struct WorktreesToast: Equatable { var message: String; var systemFallback: String }

/// One worktrees tab: bound to a single folder (a git repo with worktrees), it
/// lists the worktrees under it, computes their disk usage, and offers cache
/// clearing + worktree removal. Folder-bound rather than device-bound, so its
/// `device` is a synthetic placeholder that's never persisted or used.
@Observable
@MainActor
final class WorktreesTab: WorkspaceTab {
    let id = UUID()
    let folder: URL
    var displayName: String

    // Ported scan state.
    var phase: WorktreesPhase = .empty
    var trees: [Worktree] = []
    var openId: String? = nil
    var toast: WorktreesToast? = nil
    var isScanning = false   // true while listing + computing sizes

    private var toastTask: Task<Void, Never>?
    private let git = GitService()
    private let cleaner = CacheCleaner()
    private var watcher: FolderWatcher?

    // MARK: WorkspaceTab

    var subtitle: String { displayFolderPath }
    var isRunning: Bool { isScanning || trees.contains { $0.cleaning } }

    /// A worktrees tab is folder-bound, not device-bound. This synthetic device is
    /// never persisted (see `descriptor(for:)`) nor used for streaming.
    let device = Device(id: "worktrees", platform: .android, model: "Worktrees", state: .unknown)

    func stop() { watcher?.cancel() }

    init(folder: URL) {
        self.folder = folder
        self.displayName = folder.lastPathComponent
        startWatching(folder)
        scan()
    }

    // MARK: derived

    /// The folder is immutable per tab; `selectedFolder` mirrors the source model's API.
    var selectedFolder: URL { folder }

    var displayFolderPath: String { (folder.path as NSString).abbreviatingWithTildeInPath }

    var total: Int { trees.reduce(0) { $0 + $1.sizeMB } }
    var orphanCount: Int { trees.filter(\.orphan).count }

    // MARK: toast

    func flash(_ message: String, fallback: String = "checkmark") {
        toastTask?.cancel()
        toast = WorktreesToast(message: message, systemFallback: fallback)
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2600))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: scanning

    /// Re-list worktrees when the view appears; only do a full scan if the set changed
    /// (avoids re-`du`-ing every worktree on every open).
    func refreshOnOpen() {
        guard phase == .ready else { return }
        let git = self.git
        let folder = self.folder
        Task { [weak self] in
            guard let self, let list = try? await git.listWorktrees(in: folder) else { return }
            if Set(list.map(\.id)) != Set(self.trees.map(\.id)) {
                self.scan(announce: false)
            }
        }
    }

    /// Watches the folder so worktrees added/removed elsewhere refresh automatically.
    private func startWatching(_ folder: URL) {
        watcher?.cancel()
        watcher = FolderWatcher(url: folder) { [weak self] in
            Task { @MainActor in self?.scan(announce: false) }
        }
    }

    /// - Parameter announce: when true (launch / explicit) shows the "Scanning…" state and a
    ///   result toast; when false (watcher / on-open refresh) updates the list in place, preserving
    ///   the open row and already-computed sizes so the UI doesn't flicker.
    func scan(announce: Bool = true) {
        let folder = self.folder
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            phase = .empty
            if announce { flash("Folder not found", fallback: "folder") }
            return
        }
        if announce {
            phase = .scanning
            isScanning = true
        }
        let git = self.git
        Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await git.listWorktrees(in: folder)
                guard !list.isEmpty else {
                    self.phase = .empty
                    self.isScanning = false
                    if announce { self.flash("No worktrees found", fallback: "folder") }
                    return
                }
                // Carry over already-computed sizes for worktrees that still exist, so a
                // background refresh doesn't flash "—" before `du` finishes.
                let previous = Dictionary(uniqueKeysWithValues: self.trees.map { ($0.id, $0) })
                self.trees = list.map { fresh in
                    guard let old = previous[fresh.id], old.sizeComputed else { return fresh }
                    var merged = fresh
                    merged.sizeMB = old.sizeMB
                    merged.cacheMB = old.cacheMB
                    merged.sizeComputed = true
                    return merged
                }
                self.phase = .ready
                if announce { self.flash("Found \(list.count) worktrees") }
                await withTaskGroup(of: (String, Int, Int).self) { group in
                    for w in list {
                        group.addTask {
                            let u = await git.diskUsage(of: URL(fileURLWithPath: w.id))
                            return (w.id, u.sizeMB, u.cacheMB)
                        }
                    }
                    for await (id, size, cache) in group {
                        self.patch(id) { $0.sizeMB = size; $0.cacheMB = cache; $0.sizeComputed = true }
                    }
                }
                self.isScanning = false
            } catch {
                self.phase = .empty
                self.isScanning = false
                if announce { self.flash("Not a git repository", fallback: "folder") }
            }
        }
    }

    // MARK: helpers

    func toggle(_ id: String) { openId = (openId == id) ? nil : id }

    private func patch(_ id: String, _ mutate: (inout Worktree) -> Void) {
        guard let i = trees.firstIndex(where: { $0.id == id }) else { return }
        mutate(&trees[i])
    }

    // MARK: clear cache (animated countdown)

    /// Really clears build caches for a worktree: `./gradlew clean` (Android) + the matching iOS
    /// DerivedData. Shows "Cleaning…" while it runs, then flashes the worktree's size green and
    /// toasts how much was freed.
    func clearCache(_ id: String) {
        guard let w = trees.first(where: { $0.id == id }), !w.cleaning else { return }
        let oldSize = w.sizeMB
        let path = URL(fileURLWithPath: w.id)
        let cleaner = self.cleaner
        patch(id) { $0.cleaning = true }
        Task { [weak self] in
            let result = await cleaner.clearCache(worktree: path)
            guard let self else { return }
            let freed = max(0, oldSize - result.newSizeMB) + result.derivedFreedMB
            self.patch(id) {
                $0.cleaning = false
                $0.sizeMB = result.newSizeMB
                $0.sizeComputed = true
                $0.dropped = true
            }
            if let error = result.error {
                self.flash("Clean failed · \(error.prefix(50))", fallback: "sparkles")
            } else {
                self.flash("Freed \(formatSize(freed)) · \(w.shortName)", fallback: "sparkles")
            }
            try? await Task.sleep(for: .milliseconds(1400))
            self.patch(id) { $0.dropped = false }
        }
    }

    // MARK: prune

    /// Really removes a worktree: `git worktree remove --force` (deletes the directory too).
    /// On success the row fades out and drops from the list; on failure git's message is shown
    /// (e.g. the main working tree can't be removed) and the row stays.
    func deleteWorktree(_ id: String) {
        guard let w = trees.first(where: { $0.id == id }) else { return }
        let path = URL(fileURLWithPath: w.id)
        let repo = self.folder
        let git = self.git
        Task { [weak self] in
            guard let self else { return }
            let result = await git.removeWorktree(at: path, repo: repo)
            guard result.ok else {
                let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                self.flash(msg.isEmpty ? "Couldn't remove worktree" : msg, fallback: "eraser")
                return
            }
            self.patch(id) { $0.removing = true }
            try? await Task.sleep(for: .milliseconds(280))
            self.trees.removeAll { $0.id == id }
            self.flash("Deleted \(w.name)", fallback: "eraser")
        }
    }
}
