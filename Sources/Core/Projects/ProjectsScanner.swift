import Foundation

/// Discovers the projects to manage and their checkouts. Sources:
///  - Auto: every project Claude Code has run in, found under `~/.claude/projects`.
///    Those directory names flatten both `/` and `.` to `-` (lossy), so the real path
///    is recovered from a session's `cwd`, falling back to a filesystem-guided decode.
///  - Manual: folders the user added (which need not use Claude).
///
/// For each git-repo project the checkouts come from `git worktree list` (main working
/// tree + linked worktrees); Claude flags (managed-by-path, has-sessions) are attached
/// per checkout. Disk sizes are NOT computed here — the model fills those in the
/// background so the structural scan stays fast.
struct ProjectsScanner: Sendable {
    var claudeHome: URL
    private let git = GitService()
    private static let cwdProbeBytes = 262_144

    init(claudeHome: URL? = nil) {
        self.claudeHome = claudeHome
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    /// - Parameter userFolders: absolute paths of manually-added project folders.
    func scan(userFolders: [String] = []) async -> [Project] {
        let fm = FileManager.default

        // 1. Decode every ~/.claude/projects entry into (real path, session stats).
        let entries = claudeEntries(fm: fm)
        var claudeByPath: [String: (count: Int, last: Date?)] = [:]
        for e in entries { claudeByPath[e.path] = (e.count, e.last) }

        // 2. Project roots: Claude roots (non-worktree entries) + parents of Claude
        //    worktree entries + user folders. Track which came from Claude.
        var claudeRoots = Set<String>()
        for e in entries {
            if ProjectsGrouping.isWorktreePath(e.path) {
                if let parent = ProjectsGrouping.parentRepoPath(of: e.path) { claudeRoots.insert(parent) }
            } else {
                claudeRoots.insert(e.path)
            }
        }
        var roots = claudeRoots
        roots.formUnion(userFolders)

        // 3. Build a project per root.
        var projects: [Project] = []
        for root in roots {
            let exists = fm.fileExists(atPath: root)
            let isGit = exists && fm.fileExists(atPath: (root as NSString).appendingPathComponent(".git"))
            let source: ProjectSource = claudeRoots.contains(root) ? .claude : .user
            let rootClaude = claudeByPath[root]

            var checkouts: [ProjectCheckout] = []
            if isGit, let trees = try? await git.listWorktrees(in: URL(fileURLWithPath: root)) {
                checkouts = trees.map { checkout(from: $0, root: root, claudeByPath: claudeByPath, fm: fm) }
            }

            projects.append(Project(
                path: root, exists: exists, isGitRepo: isGit, source: source,
                sessionCount: rootClaude?.count ?? 0, lastActive: rootClaude?.last,
                checkouts: checkouts
            ))
        }

        return ProjectsGrouping.sorted(ProjectsGrouping.activeOnly(projects))
    }

    // MARK: - Checkout mapping

    private func checkout(from w: Worktree, root: String,
                          claudeByPath: [String: (count: Int, last: Date?)],
                          fm: FileManager) -> ProjectCheckout {
        let claude = claudeByPath[w.id]
        return ProjectCheckout(
            path: w.id,
            isMain: w.id == root,
            branch: w.name,
            base: w.base == "—" ? nil : w.base,
            age: w.age == "—" ? nil : w.age,
            exists: fm.fileExists(atPath: w.id),
            orphan: w.orphan,
            orphanKind: w.kind,
            isClaudeManaged: ProjectsGrouping.isWorktreePath(w.id),
            hasClaudeSessions: (claude?.count ?? 0) > 0,
            claudeSessionCount: claude?.count ?? 0,
            claudeLastActive: claude?.last,
            lastCommit: w.lastCommit
        )
    }

    // MARK: - ~/.claude/projects decoding

    private struct ClaudeEntry { var path: String; var count: Int; var last: Date? }

    private func claudeEntries(fm: FileManager) -> [ClaudeEntry] {
        let projectsDir = claudeHome.appendingPathComponent("projects")
        guard let dirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var entries: [ClaudeEntry] = []
        for dir in dirs {
            let encoded = dir.lastPathComponent
            guard encoded.hasPrefix("-") else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let jsonls = sessionFiles(in: dir, fm: fm)
            let path = cwdFromSessions(jsonls)
                ?? Self.decodeViaFilesystem(encoded, fm: fm)
                ?? Self.naiveDecode(encoded)
            entries.append(ClaudeEntry(path: path, count: jsonls.count, last: lastModified(of: jsonls)))
        }
        return entries
    }

    private func sessionFiles(in dir: URL, fm: FileManager) -> [URL] {
        let contents = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return contents.filter { $0.pathExtension == "jsonl" }
    }

    private func lastModified(of files: [URL]) -> Date? {
        files.compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max()
    }

    private func cwdFromSessions(_ jsonls: [URL]) -> String? {
        for file in jsonls {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: Self.cwdProbeBytes)) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            if let cwd = ClaudeSessionProbe.extractCwd(fromJSONL: text) { return cwd }
        }
        return nil
    }

    // MARK: - Path decoding

    /// Recovers a real path by walking the filesystem: at each level pick the child
    /// whose name (with `.`→`-`) is the longest prefix of the remaining encoded string.
    static func decodeViaFilesystem(_ encoded: String, fm: FileManager) -> String? {
        guard encoded.hasPrefix("-") else { return nil }
        var rest = String(encoded.dropFirst())
        var current = "/"
        while !rest.isEmpty {
            guard let children = try? fm.contentsOfDirectory(atPath: current) else { return nil }
            var best: (name: String, enc: String)?
            for child in children {
                let enc = child.replacingOccurrences(of: ".", with: "-")
                guard rest == enc || rest.hasPrefix(enc + "-") else { continue }
                if best == nil || enc.count > best!.enc.count { best = (child, enc) }
            }
            guard let pick = best else { return nil }
            current = (current as NSString).appendingPathComponent(pick.name)
            rest = String(rest.dropFirst(pick.enc.count))
            if rest.hasPrefix("-") { rest = String(rest.dropFirst()) }
        }
        return current
    }

    /// Last-resort decode: treat every `-` as `/`. Only reached for folders that no
    /// longer exist on disk (so the filesystem walk can't resolve them).
    static func naiveDecode(_ encoded: String) -> String {
        let trimmed = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        return "/" + trimmed.replacingOccurrences(of: "-", with: "/")
    }
}
