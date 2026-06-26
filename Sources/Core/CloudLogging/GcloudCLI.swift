import Foundation

/// Typed wrappers over the `gcloud` CLI for Cloud Logging. One-shot subprocesses via
/// `CommandRunner`; the filter is passed as a single argv element (no shell), so the
/// double-quotes inside a Logging filter need no extra escaping. Stderr is classified into
/// actionable errors (not-authenticated / no-permission / not-found).
struct GcloudCLI: Sendable {
    let binary: URL

    private var environment: [String: String] { GcloudToolchain.environment(for: binary) }

    /// Runs a gcloud subcommand and records it (command + exit + stderr + stdout) in the shared
    /// debug log, so the debug console can show exactly what Jaca ran and why it failed.
    private func run(_ args: [String], timeout: TimeInterval) async throws -> CommandRunner.Result {
        let start = Date()
        let result = try await CommandRunner.run(binary, args, environment: environment, timeout: timeout)
        GcloudDebugLog.shared.record(
            command: GcloudDebugLog.command(binary, args),
            exitCode: result.exitCode, stderr: result.stderr, stdout: result.stdout,
            durationMs: Int(Date().timeIntervalSince(start) * 1000))
        return result
    }

    enum CLIError: Error, LocalizedError, Equatable {
        case notAuthenticated
        case noPermission(String)
        case notFound(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "You're not signed in to gcloud. Run `gcloud auth login` in a terminal."
            case .noPermission(let p):
                return "Your account doesn't have access to logs in “\(p)”."
            case .notFound(let p):
                return "Project “\(p)” wasn't found (or you can't access it)."
            case .failed(let m):
                return m
            }
        }
    }

    struct Account: Sendable, Hashable { let account: String; let active: Bool }

    // MARK: - Auth

    /// All configured accounts; an entry with `active == true` is the one in use.
    func accounts() async -> [Account] {
        guard let r = try? await run(["auth", "list", "--format=json"], timeout: 20),
              r.exitCode == 0, let data = r.stdout.data(using: .utf8),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr.map {
            Account(account: $0["account"] as? String ?? "",
                    active: ($0["status"] as? String)?.uppercased() == "ACTIVE")
        }
    }

    /// The active account email, or nil if not signed in.
    func activeAccount() async -> String? {
        await accounts().first { $0.active }?.account
    }

    // MARK: - Projects & logs

    /// Validates a project id is reachable by the active account. Throws on failure.
    func describeProject(_ id: String) async throws {
        let r = try await run(["projects", "describe", id, "--format=json"], timeout: 30)
        if r.exitCode == 0 { return }
        throw classify(r, project: id)
    }

    /// The full log names (`projects/<id>/logs/<encoded>`) that have entries in the project.
    func listLogNames(project: String) async throws -> [String] {
        let r = try await run(["logging", "logs", "list", "--project=\(project)", "--format=json"], timeout: 45)
        guard r.exitCode == 0 else { throw classify(r, project: project) }
        guard let data = r.stdout.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["name"] as? String }.sorted()
    }

    // MARK: - Read

    /// One-shot read. With `order == "asc"` the entries are oldest→newest. `gcloud` pages
    /// internally up to `limit`.
    func read(project: String, filter: String, order: String = "asc", limit: Int = 1000) async throws -> [CloudLogEntry] {
        var args = ["logging", "read", filter, "--project=\(project)", "--format=json", "--order=\(order)"]
        args.append("--limit=\(limit)")
        let r = try await run(args, timeout: 120)
        guard r.exitCode == 0 else { throw classify(r, project: project) }
        return CloudLogEntryDecoder.decodeArray(Data(r.stdout.utf8))
    }

    // MARK: - Error classification

    private func classify(_ r: CommandRunner.Result, project: String) -> CLIError {
        let text = (r.stderr + " " + r.stdout).lowercased()
        if text.contains("do not currently have active credentials")
            || text.contains("gcloud auth login")
            || text.contains("application default credentials")
            || text.contains("reauthentication")
            || text.contains("invalid_grant")
            || text.contains("there was a problem refreshing") {
            return .notAuthenticated
        }
        if text.contains("permission") && text.contains("denied") { return .noPermission(project) }
        if text.contains("permission_denied") { return .noPermission(project) }
        if text.contains("not_found") || text.contains("could not be found")
            || text.contains("does not exist") || text.contains("was not found") {
            return .notFound(project)
        }
        let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(msg.isEmpty ? "gcloud exited with code \(r.exitCode)" : firstLines(msg))
    }

    private func firstLines(_ s: String, max: Int = 4) -> String {
        s.split(separator: "\n").prefix(max).joined(separator: "\n")
    }
}
