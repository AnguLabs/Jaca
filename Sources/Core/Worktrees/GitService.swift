import Foundation

enum GitError: Error { case notARepository(String) }

struct GitService: Sendable {
    private let git = "/usr/bin/git"
    private let cacheDirs = ["node_modules", "build", ".gradle", "DerivedData", "Pods", "ios/build", "android/.cxx", ".expo"]

    /// Runs `exe args…` to completion. Launch failures are folded into `ok == false`
    /// (CommandRunner throws on launch failure but git/du queries treat that as "no result").
    private func sh(_ exe: String, _ args: [String]) async -> (ok: Bool, out: String, err: String) {
        guard let r = try? await CommandRunner.run(URL(fileURLWithPath: exe), args) else { return (false, "", "") }
        return (r.exitCode == 0, r.stdout, r.stderr)
    }

    func listWorktrees(in folder: URL) async throws -> [Worktree] {
        let res = await sh(git, ["-C", folder.path, "worktree", "list", "--porcelain"])
        guard res.ok else { throw GitError.notARepository(res.err) }

        let entries = WorktreePorcelainParser.parse(res.out)
        var trees: [Worktree] = []
        for e in entries {
            let url = URL(fileURLWithPath: e.path)
            let name: String, orphan: Bool, kind: OrphanKind?
            if e.detached {
                name = "detached @ " + String((e.head ?? "").prefix(7)); orphan = true; kind = .detached
            } else if e.prunable {
                name = e.branch ?? url.lastPathComponent; orphan = true; kind = .deleted
            } else {
                name = e.branch ?? url.lastPathComponent; orphan = false; kind = nil
            }
            let base = orphan ? "—" : (await upstream(of: url) ?? "—")
            let commit = await lastCommit(of: url)
            trees.append(Worktree(id: e.path, name: name, base: base, age: commit.relative ?? "—",
                                  lastCommit: commit.date,
                                  sizeMB: 0, cacheMB: 0, orphan: orphan, kind: kind))
        }
        return trees
    }

    private func upstream(of worktree: URL) async -> String? {
        let res = await sh(git, ["-C", worktree.path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
        guard res.ok else { return nil }
        let up = res.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !up.isEmpty else { return nil }
        // "origin/feature/foo" -> "feature/foo"; "origin/main" -> "main"
        let parts = up.split(separator: "/")
        guard parts.count > 1 else { return up }
        return parts.dropFirst().joined(separator: "/")
    }

    /// HEAD's committer date as both a raw `Date` (for ordering) and git's own relative
    /// string (for display) — fetched in one `git log` so sorting costs no extra process.
    private func lastCommit(of worktree: URL) async -> (date: Date?, relative: String?) {
        let res = await sh(git, ["-C", worktree.path, "log", "-1", "--format=%ct%n%cr"])
        guard res.ok else { return (nil, nil) }
        let lines = res.out.split(separator: "\n", omittingEmptySubsequences: false)
        let date = lines.first
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            .map { Date(timeIntervalSince1970: $0) }
        let relative = lines.count > 1
            ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (date, relative.isEmpty ? nil : relative)
    }

    /// Removes a worktree from git and deletes its directory (`--force`, so dirty trees go too).
    /// Returns (ok, stderr) so the caller can surface git's message on failure (e.g. the main
    /// working tree can't be removed).
    func removeWorktree(at path: URL, repo: URL) async -> (ok: Bool, stderr: String) {
        let res = await sh(git, ["-C", repo.path, "worktree", "remove", "--force", path.path])
        return (res.ok, res.err)
    }

    /// Returns (total MB, cache MB) for a worktree, in a single concurrent traversal
    /// (see `DirectorySizer`). Failures yield 0.
    func diskUsage(of worktree: URL) async -> (sizeMB: Int, cacheMB: Int) {
        let (total, cache) = await DirectorySizer(cacheDirs: Set(cacheDirs)).size(worktree)
        let mb = 1024 * 1024
        return (sizeMB: Int(total) / mb, cacheMB: Int(cache) / mb)
    }
}
