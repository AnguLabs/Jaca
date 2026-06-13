import Foundation

/// Lists and kills running Gradle daemon processes by shelling out to `ps`/`kill`.
/// A daemon is any process whose command line contains "GradleDaemon".
struct GradleDaemonService: Sendable {
    private static let versionRegex = try? NSRegularExpression(pattern: "GradleDaemon ([0-9][0-9.]*)")

    /// Snapshots the running Gradle daemons via `ps`, sorted by pid.
    func list() async -> [GradleDaemon] {
        guard let result = try? await CommandRunner.run(
            URL(fileURLWithPath: "/bin/ps"),
            ["-axo", "pid=,etime=,pcpu=,rss=,command="]
        ) else { return [] }

        var daemons: [GradleDaemon] = []
        for rawLine in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.contains("GradleDaemon"), !line.contains("grep") else { continue }
            // Fields: pid etime pcpu rss command (command may contain spaces → maxSplits 4).
            let parts = line
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, let pid = Int32(parts[0]) else { continue }

            let command = String(parts[4])
            let daemon = GradleDaemon(
                pid: pid,
                version: parseVersion(from: command),
                uptime: friendlyUptime(String(parts[1])),
                cpu: Double(parts[2]) ?? 0,
                memoryMB: (Int(parts[3]) ?? 0) / 1024,  // rss is reported in KB
                jdk: firstGroup(#"(\d+)(?:\.\d+)*\.jdk"#, command),     // …/zulu-21.jdk/… → "21"
                maxHeap: firstGroup(#"-Xmx(\S+)"#, command)            // -Xmx12g → "12g"
            )
            daemons.append(daemon)
        }
        return daemons.sorted { $0.pid < $1.pid }
    }

    /// Kills the daemon. Tries a plain SIGTERM first, then SIGKILL if that fails.
    /// Returns true if either succeeded (exit code 0).
    func kill(pid: Int32) async -> Bool {
        let kill = URL(fileURLWithPath: "/bin/kill")
        if let r = try? await CommandRunner.run(kill, [String(pid)]), r.exitCode == 0 {
            return true
        }
        if let r = try? await CommandRunner.run(kill, ["-9", String(pid)]), r.exitCode == 0 {
            return true
        }
        return false
    }

    /// Per-version sizes of `~/.gradle/caches/<version>` (the version-specific build caches),
    /// largest first. (`du` can be slow on big caches, so this is computed on demand, not polled.)
    func cacheSizes() async -> [GradleCacheEntry] {
        let caches = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gradle/caches")
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: caches, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var entries: [GradleCacheEntry] = []
        for dir in dirs {
            let name = dir.lastPathComponent
            // Only version-named dirs (e.g. "9.4.1", "8.10") — skip modules-2/transforms-*/etc.
            guard name.range(of: #"^\d+\.\d+"#, options: .regularExpression) != nil else { continue }
            let kb = await duKB(dir.path)
            entries.append(GradleCacheEntry(version: name, sizeMB: kb / 1024))
        }
        return entries.sorted { $0.sizeMB > $1.sizeMB }
    }

    /// Deletes `~/.gradle/caches/<version>`. Returns true on success.
    func deleteCache(version: String) async -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gradle/caches/\(version)")
        do { try FileManager.default.removeItem(at: dir); return true }
        catch { return false }
    }

    private func duKB(_ path: String) async -> Int {
        guard let r = try? await CommandRunner.run(URL(fileURLWithPath: "/usr/bin/du"), ["-sk", path]) else { return 0 }
        let first = r.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).first
        return Int(first ?? "") ?? 0
    }

    // MARK: - Parsing

    /// First capture group of `pattern` in `s`, or nil.
    private func firstGroup(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private func parseVersion(from command: String) -> String {
        guard let regex = Self.versionRegex else { return "?" }
        let range = NSRange(command.startIndex..., in: command)
        guard let match = regex.firstMatch(in: command, range: range),
              match.numberOfRanges > 1,
              let group = Range(match.range(at: 1), in: command) else { return "?" }
        return String(command[group])
    }

    /// `ps` etime is `[[dd-]hh:]mm:ss`. Parse to seconds, then format friendly.
    private func friendlyUptime(_ etime: String) -> String {
        var days = 0
        var rest = etime

        if let dash = rest.firstIndex(of: "-") {
            days = Int(rest[rest.startIndex..<dash]) ?? 0
            rest = String(rest[rest.index(after: dash)...])
        }

        // rest is now "[hh:]mm:ss"
        let comps = rest.split(separator: ":").map { Int($0) ?? 0 }
        var hours = 0, minutes = 0, seconds = 0
        switch comps.count {
        case 3: hours = comps[0]; minutes = comps[1]; seconds = comps[2]
        case 2: minutes = comps[0]; seconds = comps[1]
        case 1: seconds = comps[0]
        default: break
        }

        let total = days * 86_400 + hours * 3_600 + minutes * 60 + seconds
        if total >= 86_400 {
            return "\(total / 86_400)d \((total % 86_400) / 3_600)h"
        } else if total >= 3_600 {
            return "\(total / 3_600)h \((total % 3_600) / 60)m"
        } else if total >= 60 {
            return "\(total / 60)m"
        } else {
            return "\(total)s"
        }
    }
}
