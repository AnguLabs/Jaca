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
                memoryMB: (Int(parts[3]) ?? 0) / 1024   // rss is reported in KB
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

    // MARK: - Parsing

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
