import Foundation

/// Clears build caches for a KMP/Android worktree: the per-worktree Gradle cache
/// (`.gradle/`), every module's build outputs (`build/`), and the matching iOS Xcode
/// DerivedData (which lives outside the worktree, keyed by WorkspacePath). All of these
/// are gitignored and regenerated on the next build, so deleting them never touches
/// source or uncommitted changes.
struct CacheCleaner: Sendable {
    /// - Returns: the worktree's size after cleaning, MB freed from iOS DerivedData (outside the
    ///   worktree), and an optional error message.
    func clearCache(worktree: URL) async -> (newSizeMB: Int, derivedFreedMB: Int, error: String?) {
        // iOS: measure + delete DerivedData whose WorkspacePath points inside this worktree.
        let derivedFreedKB = await deleteIOSDerivedData(for: worktree)

        // Android/Gradle: delete the per-worktree Gradle cache (.gradle/) and every build/
        // output directory. We remove these directly instead of running `./gradlew clean`,
        // which is slow, needs a working JDK, spawns a daemon, and — crucially — leaves the
        // per-worktree `.gradle/` behind (it can be many GB; `clean` only removes `build/`).
        var errorMessage: String?
        let fm = FileManager.default

        let dotGradle = worktree.appendingPathComponent(".gradle")
        if fm.fileExists(atPath: dotGradle.path) {
            do { try fm.removeItem(at: dotGradle) }
            catch { errorMessage = "couldn't remove .gradle: \(error.localizedDescription)" }
        }

        // Remove every `build/` directory under the worktree (don't descend into matched ones).
        if let result = try? await CommandRunner.run(
            URL(fileURLWithPath: "/usr/bin/find"),
            [worktree.path, "-type", "d", "-name", "build", "-prune", "-exec", "/bin/rm", "-rf", "{}", "+"]
        ), result.exitCode != 0, errorMessage == nil {
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty { errorMessage = msg }
        }

        let newSizeKB = await duKB(worktree.path)
        return (newSizeMB: newSizeKB / 1024, derivedFreedMB: derivedFreedKB / 1024, error: errorMessage)
    }

    /// Deletes every DerivedData folder whose `WorkspacePath` is inside `worktree`. Returns KB freed.
    private func deleteIOSDerivedData(for worktree: URL) async -> Int {
        let dd = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dd, includingPropertiesForKeys: nil
        ) else { return 0 }

        var freedKB = 0
        for dir in entries {
            let info = dir.appendingPathComponent("info.plist")
            guard let data = try? Data(contentsOf: info),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let workspacePath = plist["WorkspacePath"] as? String,
                  workspacePath.hasPrefix(worktree.path)
            else { continue }

            freedKB += await duKB(dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        return freedKB
    }

    private func duKB(_ path: String) async -> Int {
        guard let res = try? await CommandRunner.run(URL(fileURLWithPath: "/usr/bin/du"), ["-sk", path]) else { return 0 }
        let first = res.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).first
        return Int(first ?? "") ?? 0
    }
}
