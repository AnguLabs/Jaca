import Foundation

enum OrphanKind: Hashable, Codable { case deleted, detached }

struct Worktree: Identifiable, Hashable {
    let id: String
    var name: String
    var base: String
    var age: String
    /// Raw committer date of the last commit (HEAD) — the sort key behind `age`'s string.
    var lastCommit: Date? = nil
    var sizeMB: Int
    var cacheMB: Int
    var orphan: Bool = false
    var kind: OrphanKind? = nil
    var cleaning: Bool = false
    var dropped: Bool = false   // green flash after clear
    var removing: Bool = false  // fade-out before prune
    var sizeComputed: Bool = false   // true once du has populated sizeMB/cacheMB
}

extension Worktree {
    /// Last path segment of the branch name (e.g. "checkout-redesign" from "feature/checkout-redesign").
    var shortName: String { name.split(separator: "/").last.map(String.init) ?? name }
}

func formatSize(_ mb: Int) -> String {
    if mb >= 1024 { return String(format: "%.2f GB", Double(mb) / 1024.0) }
    return "\(mb) MB"
}
