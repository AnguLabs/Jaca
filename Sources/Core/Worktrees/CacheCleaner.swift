import Foundation

/// Clears build caches for a KMP worktree: `./gradlew clean` (Android/Gradle) and the matching
/// iOS Xcode DerivedData (which lives outside the worktree, keyed by WorkspacePath).
struct CacheCleaner: Sendable {
    /// - Returns: the worktree's size after cleaning, MB freed from iOS DerivedData (outside the
    ///   worktree), and an optional error message from the gradle clean.
    func clearCache(worktree: URL) async -> (newSizeMB: Int, derivedFreedMB: Int, error: String?) {
        // iOS: measure + delete DerivedData whose WorkspacePath points inside this worktree.
        let derivedFreedKB = await deleteIOSDerivedData(for: worktree)

        // Android/Gradle: `./gradlew clean` via a login shell so it inherits PATH/JAVA_HOME
        // (a GUI app's spawned process otherwise has a minimal env without the JDK). There's no
        // cwd parameter on CommandRunner, so cd into the worktree inside the shell command.
        var error: String?
        let gradlew = worktree.appendingPathComponent("gradlew")
        if FileManager.default.fileExists(atPath: gradlew.path) {
            let cmd = "cd '\(worktree.path)' && export JAVA_HOME=\"$(/usr/libexec/java_home 2>/dev/null)\"; export ANDROID_HOME=\"${ANDROID_HOME:-$HOME/Library/Android/sdk}\"; ./gradlew clean"
            let r = try? await CommandRunner.run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", cmd])
            if r == nil || r!.exitCode != 0 {
                let msg = (r?.stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                error = msg.isEmpty ? "gradlew clean failed" : msg
            }
        }

        let newSizeKB = await duKB(worktree.path)
        return (newSizeMB: newSizeKB / 1024, derivedFreedMB: derivedFreedKB / 1024, error: error)
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
