import Foundation

/// Auto-detects `labels.*` keys from streamed entries (req 9.3) — the app can't know a
/// project's labels up-front, so it learns them as logs arrive and caches them per log name.
/// Pure → unit-tested.
enum LabelDetector {
    /// Distinct entry-label keys present in a batch.
    static func keys(in entries: [CloudLogEntry]) -> Set<String> {
        var out: Set<String> = []
        for entry in entries {
            for key in entry.labels.keys { out.insert(key) }
        }
        return out
    }

    /// Merges newly seen keys into a sorted known list. Returns the merged list and whether
    /// anything was added (so callers only persist on a real change).
    static func merge(_ known: [String], with newKeys: Set<String>) -> (merged: [String], changed: Bool) {
        let existing = Set(known)
        let added = newKeys.subtracting(existing)
        guard !added.isEmpty else { return (known, false) }
        return (existing.union(added).sorted(), true)
    }
}
