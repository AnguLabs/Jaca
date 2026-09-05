import Foundation
import Darwin

/// Single-pass directory sizer: one traversal yields both the total size and the
/// cache-dir size, instead of one `du` over the whole tree plus one extra `du` per
/// cache dir.
///
///  - **One walk**: each directory is read once; bytes accumulate as we go.
///  - **Actual on-disk size** via `lstat` `st_blocks * 512`, capped at the logical
///    size so sparse / cloud-dataless files aren't over-counted.
///  - **Fixed width**: directories are read in batches of `width`, drained from an
///    explicit stack. One task group per batch — never one per directory — so the
///    thread count stays flat however deep or wide the tree is.
///  - **Cancellable**: the stack drain stops at the next batch boundary when the
///    enclosing task is cancelled, so a superseded scan doesn't keep burning cores.
///  - **Hardlink dedup**: a file with `st_nlink > 1` is counted once per (dev, inode).
struct DirectorySizer: Sendable {
    /// Cache subtrees to attribute to `cacheBytes`, as paths relative to the root
    /// (e.g. "node_modules", "ios/build"). Matched exactly, like the old `du` code.
    let cacheDirs: Set<String>

    /// Directories read concurrently inside one `size(_:)`. A small fraction of the
    /// core count on purpose: several checkouts are sized at a time (see
    /// `ProjectsModel.computeSizes`), and directory reads saturate on I/O well before CPU.
    static let width = max(2, ProcessInfo.processInfo.activeProcessorCount / 4)

    /// Returns (total, cache) allocated bytes for `root` in a single traversal.
    /// Cancelling the calling task returns the bytes counted so far.
    func size(_ root: URL) async -> (totalBytes: Int64, cacheBytes: Int64) {
        let seen = InodeSet()
        var pending = [Entry(path: root.path, rel: "", inCache: false)]
        var total: Int64 = 0
        var cache: Int64 = 0

        while !pending.isEmpty, !Task.isCancelled {
            let batch = pending.suffix(Self.width)
            pending.removeLast(batch.count)

            await withTaskGroup(of: Level.self) { group in
                for entry in batch {
                    group.addTask { Self.read(entry, cacheDirs: cacheDirs, seen: seen) }
                }
                for await level in group {
                    total += level.total
                    cache += level.cache
                    pending.append(contentsOf: level.children)
                }
            }
        }
        return (total, cache)
    }

    private static func read(_ entry: Entry, cacheDirs: Set<String>, seen: InodeSet) -> Level {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: entry.path) else {
            return Level()
        }
        var level = Level()
        for name in names {
            let full = entry.path + "/" + name
            var st = stat()
            guard lstat(full, &st) == 0 else { continue }

            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                let rel = entry.rel.isEmpty ? name : entry.rel + "/" + name
                level.children.append(Entry(
                    path: full, rel: rel, inCache: entry.inCache || cacheDirs.contains(rel)
                ))
            case S_IFREG:
                if st.st_nlink > 1, !seen.insert(dev: st.st_dev, ino: st.st_ino) { continue }
                let bytes = allocatedSize(&st)
                level.total += bytes
                if entry.inCache { level.cache += bytes }
            default:
                continue // Symlinks and everything else contribute nothing (matches `du`).
            }
        }
        return level
    }

    /// On-disk usage: block count × 512, but never more than the logical size so
    /// sparse / dataless files (blocks == 0) don't inflate the total.
    private static func allocatedSize(_ st: inout stat) -> Int64 {
        let allocated = Int64(st.st_blocks) * 512
        let logical = Int64(st.st_size)
        return allocated < logical ? allocated : logical
    }

    private struct Entry: Sendable {
        let path: String
        let rel: String
        let inCache: Bool
    }

    private struct Level: Sendable {
        var total: Int64 = 0
        var cache: Int64 = 0
        var children: [Entry] = []
    }
}

/// Thread-safe set of (device, inode) pairs for hardlink dedup within one scan.
private final class InodeSet: @unchecked Sendable {
    private struct Key: Hashable { let dev: dev_t; let ino: ino_t }
    private var seen = Set<Key>()
    private let lock = NSLock()

    /// Returns true if this (dev, ino) is new (i.e. should be counted).
    func insert(dev: dev_t, ino: ino_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.insert(Key(dev: dev, ino: ino)).inserted
    }
}
