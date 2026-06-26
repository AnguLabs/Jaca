import Foundation

/// Orders detected label keys with favorited ones pinned to the top, so a user's favorite labels
/// always appear first in the picker. Pure → unit-tested.
enum CloudLabelOrdering {
    /// `keys` with the favorited ones first (both groups sorted). Favorites that are no longer in
    /// `keys` (the log stopped emitting them) are dropped.
    static func ordered(keys: [String], favorites: [String]) -> [String] {
        let favoriteSet = Set(favorites)
        let pinned = keys.filter { favoriteSet.contains($0) }.sorted()
        let rest = keys.filter { !favoriteSet.contains($0) }.sorted()
        return pinned + rest
    }
}
