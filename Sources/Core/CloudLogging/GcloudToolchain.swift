import Foundation

/// Locates the `gcloud` CLI and builds an environment that can find it. A GUI app doesn't
/// inherit the login-shell PATH, and the SDK installs in several well-known spots, so we
/// check those first, then the inherited PATH, then (async) the login shell. Mirrors
/// `HerdrService.binaryURL()` / `resolveBinaryURL()`.
enum GcloudToolchain {
    private static var candidatePaths: [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin/gcloud",
            "/usr/local/bin/gcloud",
            "\(home)/google-cloud-sdk/bin/gcloud",
            "\(home)/.google-cloud-sdk/bin/gcloud",
            "/usr/local/share/google-cloud-sdk/bin/gcloud",
            "/opt/google-cloud-sdk/bin/gcloud",
            "/usr/lib/google-cloud-sdk/bin/gcloud",
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
            let candidate = "\(dir)/gcloud"
            if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// Like `binaryURL()`, but falls back to the login-shell PATH (`zsh -lc 'command -v gcloud'`),
    /// catching installs the GUI app's environment can't see. Async (spawns a shell), so resolve
    /// off the render path.
    static func resolveBinaryURL() async -> URL? {
        if let url = binaryURL() { return url }
        guard let result = try? await CommandRunner.run(
            URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v gcloud"]
        ), result.exitCode == 0 else { return nil }
        let path = result.stdout
            .split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Environment for spawning gcloud: prepends the SDK `bin` dir to PATH (so gcloud finds its
    /// bundled python + components) and disables interactive prompts.
    static func environment(for binary: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let binDir = binary.deletingLastPathComponent().path
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        if !existing.split(separator: ":").map(String.init).contains(binDir) {
            env["PATH"] = "\(binDir):\(existing)"
        }
        env["CLOUDSDK_CORE_DISABLE_PROMPTS"] = "1"
        return env
    }
}
