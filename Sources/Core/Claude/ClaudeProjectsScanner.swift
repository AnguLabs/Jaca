import Foundation

/// Scans `~/.claude/projects/` to discover Claude Code projects and their worktrees.
///
/// Each subdirectory there is named after a project's absolute path with both `/` and
/// `.` flattened to `-` (a lossy encoding), so the real path is recovered from a
/// session file's `cwd`, falling back to a filesystem-guided decode of the directory
/// name, and finally a naive decode for folders that no longer exist. Worktrees are
/// derived from `.claude/worktrees/` session dirs and enriched via `git worktree list`.
struct ClaudeProjectsScanner: Sendable {
    var claudeHome: URL
    private let git = GitService()
    /// Cap how much of a session file we read just to find `cwd` (it appears near the top).
    private static let cwdProbeBytes = 262_144

    init(claudeHome: URL? = nil) {
        self.claudeHome = claudeHome
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    func scan() async -> [ClaudeProject] {
        let fm = FileManager.default
        let projectsDir = claudeHome.appendingPathComponent("projects")
        guard let dirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        // 1. Decode each project dir into a raw entry (real path + session stats).
        var entries: [ClaudeRawEntry] = []
        for dir in dirs {
            let encoded = dir.lastPathComponent
            guard encoded.hasPrefix("-") else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let jsonls = sessionFiles(in: dir, fm: fm)
            let path = cwdFromSessions(jsonls)
                ?? Self.decodeViaFilesystem(encoded, fm: fm)
                ?? Self.naiveDecode(encoded)
            entries.append(ClaudeRawEntry(
                encodedName: encoded, path: path,
                exists: fm.fileExists(atPath: path),
                sessionCount: jsonls.count, lastActive: lastModified(of: jsonls)
            ))
        }

        // 2. Ensure every worktree's parent repo appears as a (possibly synthetic) entry,
        //    so a worktree whose repo has no Claude sessions of its own still gets a home.
        let known = Set(entries.map(\.path))
        var parents = Set<String>()
        for e in entries where ClaudeProjectGrouping.isWorktreePath(e.path) {
            if let p = ClaudeProjectGrouping.parentRepoPath(of: e.path) { parents.insert(p) }
        }
        for parent in parents where !known.contains(parent) {
            entries.append(ClaudeRawEntry(
                encodedName: "", path: parent, exists: fm.fileExists(atPath: parent),
                sessionCount: 0, lastActive: nil, isSynthetic: true
            ))
        }

        // 3. Group into projects, then enrich each existing git repo with its worktrees.
        var projects = ClaudeProjectGrouping.group(entries)
        for i in projects.indices {
            guard projects[i].exists else { continue }
            let dotGit = projects[i].url.appendingPathComponent(".git").path
            projects[i].isGitRepo = fm.fileExists(atPath: dotGit)
            if projects[i].isGitRepo {
                projects[i].worktrees = await enrichWithGit(projects[i], fm: fm)
            }
        }

        // Show only active checkouts — drop worktrees (and empty projects) whose folder
        // no longer exists on disk.
        return ClaudeProjectGrouping.sorted(ClaudeProjectGrouping.activeOnly(projects))
    }

    // MARK: - Sessions

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

    // MARK: - Git enrichment

    /// Merges `git worktree list` into the project's Claude-derived worktrees: matched
    /// paths gain a branch name and commit age; git-only worktrees (no Claude session)
    /// are added so the listing is complete. The main working tree is skipped.
    private func enrichWithGit(_ project: ClaudeProject, fm: FileManager) async -> [ClaudeWorktree] {
        guard let trees = try? await git.listWorktrees(in: project.url) else { return project.worktrees }
        var byPath = Dictionary(project.worktrees.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        for t in trees where t.id != project.path {
            let age = t.age == "—" ? nil : t.age
            if var existing = byPath[t.id] {
                existing.branch = t.name
                existing.age = age
                byPath[t.id] = existing
            } else {
                byPath[t.id] = ClaudeWorktree(
                    path: t.id, exists: fm.fileExists(atPath: t.id),
                    hasClaudeSessions: false, sessionCount: 0, lastActive: nil,
                    branch: t.name, age: age
                )
            }
        }
        return Array(byPath.values)
    }

    // MARK: - Path decoding

    /// Recovers a real path by walking the filesystem: at each level pick the child
    /// whose name (with `.`→`-`) is the longest prefix of the remaining encoded string.
    /// Returns nil if the path can't be resolved on disk (folder moved/deleted).
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

    /// Last-resort decode: treat every `-` as `/`. Wrong for names containing `.` or
    /// `-`, but only reached for projects whose folder no longer exists on disk.
    static func naiveDecode(_ encoded: String) -> String {
        let trimmed = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        return "/" + trimmed.replacingOccurrences(of: "-", with: "/")
    }
}
