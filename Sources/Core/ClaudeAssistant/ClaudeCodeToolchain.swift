import Foundation

/// Locates the `claude` CLI (Claude Code) and builds an environment that can find it. A GUI app
/// doesn't inherit the login-shell PATH and Claude Code installs in a few well-known spots, so we
/// check those first, then the inherited PATH, then (async) the login shell. Mirrors
/// `GcloudToolchain`.
enum ClaudeCodeToolchain {
    private static var candidatePaths: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/node_modules/.bin/claude",
        ]
    }

    /// Cheap, synchronous resolution: well-known dirs, then every dir on the inherited PATH.
    static func binaryURL() -> URL? {
        let fm = FileManager.default
        if let hit = candidatePaths.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: hit)
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for dir in pathDirs {
            let candidate = "\(dir)/claude"
            if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// Like `binaryURL()`, but falls back to the login-shell PATH (`zsh -lc 'command -v claude'`),
    /// catching installs the GUI app's environment can't see. Async (spawns a shell).
    static func resolveBinaryURL() async -> URL? {
        if let url = binaryURL() { return url }
        guard let result = try? await CommandRunner.run(
            URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v claude"]
        ), result.exitCode == 0 else { return nil }
        let path = result.stdout
            .split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Environment for spawning `claude`: prepends its `bin` dir to PATH (so `node`/helpers
    /// resolve) and forces non-interactive output.
    static func environment(for binary: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let binDir = binary.deletingLastPathComponent().path
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        if !existing.split(separator: ":").map(String.init).contains(binDir) {
            env["PATH"] = "\(binDir):\(existing)"
        }
        env["CI"] = "1"               // discourage any interactive prompts
        env["NO_COLOR"] = "1"
        return env
    }
}
