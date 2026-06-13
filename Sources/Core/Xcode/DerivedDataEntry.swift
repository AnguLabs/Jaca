import Foundation

/// How a DerivedData entry relates to a project on disk.
enum DerivedDataKind {
    case live    // its WorkspacePath still exists
    case stale   // its WorkspacePath is gone (e.g. a deleted worktree's build)
    case shared  // a shared cache (ModuleCache.noindex, SymbolCache, …) — not project-bound
}

/// One folder under `~/Library/Developer/Xcode/DerivedData`, with its size and
/// whether the project/workspace it was built for still exists.
struct DerivedDataEntry: Identifiable, Hashable {
    var id: String { path }
    let name: String            // project name (or the cache name for shared entries)
    let path: String            // full path to the DerivedData subfolder
    let workspacePath: String?  // resolved WorkspacePath (nil for shared caches)
    let sizeMB: Int
    let kind: DerivedDataKind
    var removing: Bool = false
}
