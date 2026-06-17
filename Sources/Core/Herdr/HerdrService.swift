import Foundation

/// Drives the `herdr` CLI (its socket API) to launch a Claude Code session inside a Herdr
/// workspace + tab. Jaca is a *launcher*: it finds-or-creates the per-project Space, opens
/// a tab in the target folder, and runs the configured `claude` command in that tab's pane
/// — mirroring the user's `claude-work` reference flow. Foundation only; no UI.
///
/// Space model: one Space per project, keyed by the repo/project root (matched on the
/// workspace's `worktree.repo_root`/`checkout_path`, or its label). Every launch adds a tab.
struct HerdrService {
    /// What to launch and where.
    struct LaunchTarget: Sendable {
        /// The repo/project root — keys the Space (find-or-create).
        var projectRoot: URL
        var projectName: String
        /// Where `claude` should run: the project root or a specific worktree folder.
        var folder: URL
        /// A linked worktree → just `cd` into it. The project root → new-worktree flow.
        var isWorktree: Bool
        /// The project root is a git repo → use `claude --worktree`; otherwise plain `claude`.
        var hasGit: Bool
        /// User-typed "what we're working on" — the Herdr tab label, and (slugified) the
        /// name of the new git worktree in the project-root flow.
        var tabName: String
    }

    struct LaunchResult: Sendable {
        let workspaceLabel: String
        let tabLabel: String
    }

    enum LaunchError: Error, LocalizedError {
        case notInstalled
        case commandFailed(String)
        case badResponse(String)
        case paneNotResolved

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "herdr CLI not found"
            case .commandFailed(let m): return m
            case .badResponse(let m): return "Unexpected herdr response: \(m)"
            case .paneNotResolved: return "couldn't resolve the new tab's pane"
            }
        }
    }

    /// Common install locations for the `herdr` binary (Homebrew, /usr/local, ~/.local,
    /// ~/bin, cargo), checked before scanning PATH.
    private static let candidatePaths = [
        "/opt/homebrew/bin/herdr",
        "/usr/local/bin/herdr",
        "\(NSHomeDirectory())/.local/bin/herdr",
        "\(NSHomeDirectory())/bin/herdr",
        "\(NSHomeDirectory())/.cargo/bin/herdr",
    ]

    /// Resolves the `herdr` binary on disk, or nil if it isn't installed. Cheap + sync
    /// (no subprocess): checks the well-known install dirs, then every dir on the
    /// inherited PATH. Use `resolveBinaryURL()` for the login-shell PATH fallback.
    static func binaryURL() -> URL? {
        let fm = FileManager.default
        if let hit = candidatePaths.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: hit)
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        for dir in pathDirs {
            let candidate = "\(dir)/herdr"
            if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// Like `binaryURL()`, but falls back to resolving `herdr` against the user's
    /// login-shell PATH (`zsh -lc 'command -v herdr'`). A GUI app doesn't inherit the
    /// shell PATH, so a binary in e.g. `~/.local/bin` can be invisible to the sync check
    /// — this catches any install location. Async (spawns a shell), so resolve it off
    /// the render path (e.g. once when the Projects area loads), not per row.
    static func resolveBinaryURL() async -> URL? {
        if let url = binaryURL() { return url }
        guard let result = try? await CommandRunner.run(
            URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v herdr"]
        ), result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Runs the full launch sequence against the running herdr server, reporting each step
    /// via `onProgress` (awaited, so messages stay in order) for the app's snackbar.
    func launch(
        _ target: LaunchTarget,
        claudeCommand: String,
        onProgress: @Sendable (String) async -> Void = { _ in }
    ) async throws -> LaunchResult {
        guard let herdr = await Self.resolveBinaryURL() else { throw LaunchError.notInstalled }
        let tabLabel = target.tabName.isEmpty ? target.folder.lastPathComponent : target.tabName

        // 1. Find-or-create the project's Space (one Space per project).
        await onProgress("Finding Herdr Space for \(target.projectName)…")
        let workspaces = try await listWorkspaces(herdr)
        let rootPath = target.projectRoot.standardizedFileURL.path
        let existing = workspaces.first { ws in
            ws.worktree?.repo_root == rootPath
                || ws.worktree?.checkout_path == rootPath
                || ws.label == target.projectName
        }

        let workspaceId: String
        let workspaceLabel: String
        if let existing {
            workspaceId = existing.workspace_id
            workspaceLabel = existing.label ?? target.projectName
            _ = try? await run(herdr, ["workspace", "focus", workspaceId])
        } else {
            await onProgress("Creating Herdr Space '\(target.projectName)'…")
            workspaceId = try await createWorkspace(herdr, cwd: rootPath, label: target.projectName)
            workspaceLabel = target.projectName
        }

        // 2. New tab in the target folder.
        await onProgress("Creating tab '\(tabLabel)' in Herdr…")
        let tabId = try await createTab(herdr, workspace: workspaceId, cwd: target.folder.path, label: tabLabel)

        // 3. Resolve the tab's pane (the create response is racy — read it back).
        let paneId = try await resolvePane(herdr, workspace: workspaceId, tab: tabId)

        // 4. Run the launch line in the pane.
        await onProgress(Self.runProgress(for: target))
        let line = Self.launchLine(for: target, claudeCommand: claudeCommand)
        let result = try await run(herdr, ["pane", "run", paneId, line])
        guard result.exitCode == 0 else {
            throw LaunchError.commandFailed(Self.message(from: result))
        }

        return LaunchResult(workspaceLabel: workspaceLabel, tabLabel: tabLabel)
    }

    /// Snackbar copy for the final step, phrased to match what the pane is about to do.
    private static func runProgress(for target: LaunchTarget) -> String {
        if target.isWorktree {
            return "Opening worktree '\(target.folder.lastPathComponent)' + starting Claude…"
        }
        if target.hasGit {
            let slug = worktreeSlug(target.tabName)
            return slug.isEmpty
                ? "Creating a new worktree + starting Claude…"
                : "Creating worktree '\(slug)' + starting Claude…"
        }
        return "Starting Claude in \(target.projectName)…"
    }

    /// The single shell line `herdr pane run` executes inside the tab's shell:
    /// - linked worktree → `cd <folder> && <claude>`
    /// - project root + git → refresh to latest, then `<claude> --worktree` (new worktree)
    /// - project root, no git → `cd <folder> && <claude>`
    static func launchLine(for target: LaunchTarget, claudeCommand: String) -> String {
        let cd = "cd \(shellQuote(target.folder.path))"
        if target.isWorktree {
            return "\(cd) && \(claudeCommand)"
        }
        if target.hasGit {
            // Base the new worktree on the latest current branch (fast-forward only so it
            // never makes a merge commit or touches uncommitted work). Name the worktree
            // after the tab when possible; otherwise let claude derive one.
            let slug = worktreeSlug(target.tabName)
            let worktreeArg = slug.isEmpty ? "--worktree" : "--worktree \(shellQuote(slug))"
            return "\(cd) && git fetch --all --prune && git pull --ff-only ; \(claudeCommand) \(worktreeArg)"
        }
        return "\(cd) && \(claudeCommand)"
    }

    /// Single-quote a string for a POSIX shell, escaping embedded single quotes.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Slugifies a tab name into a git-safe worktree/branch name (mirrors the user's
    /// `claude-work` script: keep `[A-Za-z0-9._-]`, collapse the rest to `-`, cap length).
    static func worktreeSlug(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var slug = String(name.map { allowed.contains($0) ? $0 : "-" })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return String(slug.prefix(40))
    }

    // MARK: - CLI calls

    private func listWorkspaces(_ herdr: URL) async throws -> [WorkspaceInfo] {
        let result = try await run(herdr, ["workspace", "list"])
        guard result.exitCode == 0 else { throw LaunchError.commandFailed(Self.message(from: result)) }
        let decoded: Envelope<WorkspaceList> = try Self.decode(result.stdout)
        return decoded.result.workspaces
    }

    private func createWorkspace(_ herdr: URL, cwd: String, label: String) async throws -> String {
        let result = try await run(herdr, ["workspace", "create", "--cwd", cwd, "--label", label, "--focus"])
        guard result.exitCode == 0 else { throw LaunchError.commandFailed(Self.message(from: result)) }
        let decoded: Envelope<WorkspaceCreated> = try Self.decode(result.stdout)
        return decoded.result.workspace.workspace_id
    }

    private func createTab(_ herdr: URL, workspace: String, cwd: String, label: String) async throws -> String {
        let result = try await run(herdr, ["tab", "create", "--workspace", workspace, "--cwd", cwd, "--label", label, "--focus"])
        guard result.exitCode == 0 else { throw LaunchError.commandFailed(Self.message(from: result)) }
        let decoded: Envelope<TabCreated> = try Self.decode(result.stdout)
        return decoded.result.tab.tab_id
    }

    /// Polls `pane list` until the new tab's pane appears (the tab-create response doesn't
    /// carry a usable pane id yet). Gives up after a few seconds.
    private func resolvePane(_ herdr: URL, workspace: String, tab: String) async throws -> String {
        for attempt in 0..<30 {
            let result = try await run(herdr, ["pane", "list", "--workspace", workspace])
            if result.exitCode == 0,
               let decoded: Envelope<PaneList> = try? Self.decode(result.stdout),
               let pane = decoded.result.panes.first(where: { $0.tab_id == tab }) {
                return pane.pane_id
            }
            if attempt < 29 { try? await Task.sleep(for: .milliseconds(200)) }
        }
        throw LaunchError.paneNotResolved
    }

    private func run(_ herdr: URL, _ args: [String]) async throws -> CommandRunner.Result {
        try await CommandRunner.run(herdr, args)
    }

    // MARK: - JSON

    private static func decode<T: Decodable>(_ json: String) throws -> T {
        guard let data = json.data(using: .utf8) else { throw LaunchError.badResponse(json) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw LaunchError.badResponse(String(json.prefix(200))) }
    }

    private static func message(from result: CommandRunner.Result) -> String {
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "herdr exited with code \(result.exitCode)" : out
    }
}

// MARK: - Response models (only the fields we use)

private struct Envelope<R: Decodable>: Decodable { let result: R }

private struct WorkspaceList: Decodable { let workspaces: [WorkspaceInfo] }

private struct WorkspaceInfo: Decodable {
    let workspace_id: String
    let label: String?
    let worktree: WorktreeInfo?
}

private struct WorktreeInfo: Decodable {
    let checkout_path: String?
    let repo_root: String?
}

private struct WorkspaceCreated: Decodable { let workspace: IdHolder }
private struct IdHolder: Decodable { let workspace_id: String }

private struct TabCreated: Decodable { let tab: TabIdHolder }
private struct TabIdHolder: Decodable { let tab_id: String }

private struct PaneList: Decodable { let panes: [PaneInfo] }
private struct PaneInfo: Decodable { let pane_id: String; let tab_id: String }
