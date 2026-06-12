import Foundation

struct WorktreeEntry: Equatable {
    var path: String
    var head: String?
    var branch: String?   // short name; nil when detached
    var detached: Bool = false
    var prunable: Bool = false
    var bare: Bool = false
}

/// Parses `git worktree list --porcelain` output into entries.
/// Blocks are separated by blank lines; each starts with a `worktree <path>` line.
/// Bare entries are dropped (they aren't real worktrees).
enum WorktreePorcelainParser {
    static func parse(_ output: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?

        func flush() {
            if let c = current, !c.bare { entries.append(c) }
            current = nil
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("worktree ") {
                flush()
                current = WorktreeEntry(path: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                current?.branch = ref.replacingOccurrences(of: "refs/heads/", with: "")
            } else if line == "detached" {
                current?.detached = true
            } else if line == "bare" {
                current?.bare = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                current?.prunable = true
            }
        }
        flush()
        return entries
    }
}
