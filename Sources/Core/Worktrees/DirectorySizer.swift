import Foundation
import Darwin

/// Single-pass concurrent directory sizer, modeled on Mole's `calculateDirSizeFast`
/// (github.com/tw93/Mole, cmd/analyze/scanner.go).
///
/// One traversal computes **both** the total size and the cache-dir size, instead of
/// the old approach of one `du` over the whole tree plus one extra `du` per cache dir
/// (which re-walked the largest subtrees). Key techniques borrowed from Mole:
///
///  - **One walk**: each directory is `readdir`'d once; bytes accumulate as we go.
///  - **Actual on-disk size** via `lstat` `st_blocks * 512`, capped at the logical
///    size so sparse / cloud-dataless files aren't over-counted.
///  - **Bounded concurrency**: a shared limiter caps how many directory walks run at
///    once across *all* worktrees to `activeProcessorCount`; when full we recurse
///    synchronously instead of spawning (no unbounded task fan-out, no I/O thrash).
///  - **Hardlink dedup**: a file with `st_nlink > 1` is counted once per (dev, inode).
struct DirectorySizer: Sendable {
    /// Cache subtrees to attribute to `cacheBytes`, as paths relative to the root
    /// (e.g. "node_modules", "ios/build"). Matched exactly, like the old `du` code.
    let cacheDirs: Set<String>

    /// Shared across every concurrent `size(_:)` so N worktrees scanning at once still
    /// never exceed the machine's core count in parallel directory reads.
    private static let limiter = Limiter(max(2, ProcessInfo.processInfo.activeProcessorCount))

    /// Returns (total, cache) allocated bytes for `root` in a single traversal.
    func size(_ root: URL) async -> (totalBytes: Int64, cacheBytes: Int64) {
        await walk(root.path, rel: "", inCache: false, seen: InodeSet())
    }

    private func walk(_ dirPath: String, rel: String, inCache: Bool, seen: InodeSet) async -> (Int64, Int64) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { return (0, 0) }

        return await withTaskGroup(of: (Int64, Int64).self) { group -> (Int64, Int64) in
            var total: Int64 = 0
            var cache: Int64 = 0

            for name in names {
                let full = dirPath + "/" + name
                var st = stat()
                guard lstat(full, &st) == 0 else { continue }
                let kind = st.st_mode & S_IFMT

                if kind == S_IFDIR {
                    let childRel = rel.isEmpty ? name : rel + "/" + name
                    let childInCache = inCache || cacheDirs.contains(childRel)
                    if Self.limiter.tryAcquire() {
                        group.addTask {
                            defer { Self.limiter.release() }
                            return await self.walk(full, rel: childRel, inCache: childInCache, seen: seen)
                        }
                    } else {
                        // Pool is saturated — walk inline so we always make progress.
                        let r = await walk(full, rel: childRel, inCache: childInCache, seen: seen)
                        total += r.0; cache += r.1
                    }
                } else if kind == S_IFREG {
                    // Skip a hardlinked file we've already counted.
                    if st.st_nlink > 1, !seen.insert(dev: st.st_dev, ino: st.st_ino) { continue }
                    let bytes = allocatedSize(&st)
                    total += bytes
                    if inCache { cache += bytes }
                }
                // Symlinks and everything else contribute nothing (matches `du` default).
            }

            for await r in group { total += r.0; cache += r.1 }
            return (total, cache)
        }
    }

    /// On-disk usage: block count × 512, but never more than the logical size so
    /// sparse / dataless files (blocks == 0) don't inflate the total.
    private func allocatedSize(_ st: inout stat) -> Int64 {
        let allocated = Int64(st.st_blocks) * 512
        let logical = Int64(st.st_size)
        return allocated < logical ? allocated : logical
    }
}

/// Non-blocking bounded counter for the try-acquire-or-recurse-inline pattern.
private final class Limiter: @unchecked Sendable {
    private var available: Int
    private let lock = NSLock()

    init(_ n: Int) { available = n }

    func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard available > 0 else { return false }
        available -= 1
        return true
    }

    func release() {
        lock.lock(); available += 1; lock.unlock()
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
