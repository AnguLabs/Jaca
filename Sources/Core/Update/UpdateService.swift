import Foundation

/// Checks for and applies in-app updates by shelling into the source checkout the
/// running app was built from. Detection compares the installed commit (from the
/// build-info sidecar) against `origin/main`; the update pulls main, rebuilds, and
/// resolves the new app bundle path — preserving the user's branch + WIP.
struct UpdateService: Sendable {
    private let gitURL = URL(fileURLWithPath: "/usr/bin/git")

    /// Reads the sidecar the build script writes. nil disables the whole feature
    /// (someone else's build, or the checkout is gone).
    static func loadBuildInfo() -> BuildInfo? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jaca/build-info.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let repo = obj["repoPath"] as? String, !repo.isEmpty,
              let commit = obj["buildCommit"] as? String, !commit.isEmpty,
              FileManager.default.fileExists(atPath: repo) else { return nil }
        return BuildInfo(repoPath: repo, buildCommit: commit)
    }

    // MARK: - Detection

    /// Fetches `origin/main` and reports whether the installed commit is behind it.
    func status(_ info: BuildInfo) async -> UpdateStatus {
        let repo = info.repoPath
        _ = try? await git(repo, ["fetch", "--quiet", "origin", "main"])

        guard let remote = try? await git(repo, ["rev-parse", "origin/main"]),
              remote.exitCode == 0 else { return .unknown }
        let remoteSha = remote.stdout.trimmed
        guard !remoteSha.isEmpty, remoteSha != info.buildCommit else {
            return Self.decide(remoteSha: remoteSha, buildCommit: info.buildCommit, behind: 0, subject: "")
        }

        // Commits in origin/main not yet in the installed build.
        let behind = (try? await git(repo, ["rev-list", "--count", "\(info.buildCommit)..origin/main"]))
            .flatMap { Int($0.stdout.trimmed) } ?? 0
        let subject = (try? await git(repo, ["log", "-1", "--format=%s", "origin/main"]))?
            .stdout.trimmed ?? ""
        return Self.decide(remoteSha: remoteSha, buildCommit: info.buildCommit, behind: behind, subject: subject)
    }

    /// Pure decision from the gathered facts (kept separate so it's unit-testable).
    /// `.unknown` when we couldn't read the remote; `.upToDate` when the installed
    /// commit matches or nothing upstream is ahead; otherwise `.available`.
    static func decide(remoteSha: String, buildCommit: String, behind: Int, subject: String) -> UpdateStatus {
        let remote = remoteSha.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else { return .unknown }
        if remote == buildCommit { return .upToDate }
        guard behind > 0 else { return .upToDate }
        return .available(behind: behind, subject: subject)
    }

    // MARK: - Update

    /// Runs the update pipeline, reporting progress via `onPhase`, and returns the
    /// freshly built app bundle path. On any failure it restores the user's branch
    /// and pops the stash before rethrowing, so we never strand a half-applied state.
    func performUpdate(
        _ info: BuildInfo,
        onPhase: @escaping @Sendable (UpdatePhase) -> Void
    ) async throws -> String {
        let repo = info.repoPath
        let branch = try await step(repo, ["rev-parse", "--abbrev-ref", "HEAD"])
        let onMain = (branch == "main")
        let dirty = try await !step(repo, ["status", "--porcelain"]).isEmpty
        var stashed = false

        func restore() async {
            if !onMain { _ = try? await git(repo, ["checkout", branch]) }
            if stashed { _ = try? await git(repo, ["stash", "pop"]) }
        }

        do {
            if dirty {
                onPhase(.stashing)
                try await step(repo, ["stash", "push", "-u", "-m", "jaca-auto-update"])
                stashed = true
            }
            if !onMain {
                onPhase(.switching)
                try await step(repo, ["checkout", "main"])
            }
            onPhase(.pulling)
            try await step(repo, ["pull", "--ff-only", "origin", "main"])

            onPhase(.building)
            let appPath = try await buildAndResolveAppPath(repo)

            if !onMain {
                onPhase(.switching)
                try await step(repo, ["checkout", branch])
            }
            if stashed {
                try await step(repo, ["stash", "pop"])
                stashed = false
            }
            onPhase(.launching)
            return appPath
        } catch {
            await restore()
            throw error
        }
    }

    // MARK: - Build

    /// Regenerates the project, builds it, and echoes the resolved app bundle path.
    /// Runs through a login shell so Homebrew's `xcodegen` is on PATH (GUI apps don't
    /// inherit it). Build output is sent to stderr so stdout is just the app path.
    private func buildAndResolveAppPath(_ repo: String) async throws -> String {
        let script = """
        set -e
        cd \(shellQuote(repo))
        export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
        xcodegen generate 1>&2
        xcodebuild -project Jaca.xcodeproj -scheme Jaca -configuration Debug \
          -destination 'platform=macOS' \
          CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
          build 1>&2
        xcodebuild -project Jaca.xcodeproj -scheme Jaca -configuration Debug \
          -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
          | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d"/"n}'
        """
        let result = try await CommandRunner.run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", script])
        guard result.exitCode == 0 else {
            throw UpdateError.build(result.stderr.trimmed.isEmpty ? result.stdout.trimmed : tail(result.stderr))
        }
        let path = result.stdout.trimmed
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw UpdateError.build("Could not resolve the built app path")
        }
        return path
    }

    // MARK: - Helpers

    private func git(_ repo: String, _ args: [String]) async throws -> CommandRunner.Result {
        try await CommandRunner.run(gitURL, ["-C", repo] + args)
    }

    /// Runs a git command, throwing if it exits non-zero. Returns trimmed stdout.
    @discardableResult
    private func step(_ repo: String, _ args: [String]) async throws -> String {
        let result = try await git(repo, args)
        guard result.exitCode == 0 else {
            throw UpdateError.git(args.first ?? "?", result.stderr.trimmed.isEmpty ? result.stdout.trimmed : result.stderr.trimmed)
        }
        return result.stdout.trimmed
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Last few lines of build output, for a compact error toast.
    private func tail(_ s: String, lines: Int = 4) -> String {
        s.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
