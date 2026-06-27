import Foundation

/// Drives the `claude` CLI (Claude Code) in **headless print mode** to get a single, structured
/// suggestion. We hand it a strict **system prompt** (the caller defines the exact JSON contract)
/// plus the user's plain-language request, and parse the assistant's reply back into a `Decodable`.
///
/// Invocation: `claude -p "<user>" --system-prompt "<system>" --output-format json --model <m>`
/// run in a neutral temp directory so it doesn't pick up the current project's `CLAUDE.md`/context.
/// `--output-format json` prints an envelope whose `result` field holds the assistant's text.
struct ClaudeCodeCLI: Sendable {
    let binary: URL
    /// Model alias or full id. Sonnet is plenty for structured generation and is snappy.
    var model: String? = "sonnet"

    enum CLIError: Error, LocalizedError {
        case notInstalled
        case notAuthenticated
        case timedOut
        case failed(String)
        case emptyResponse
        case unparseableJSON(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Claude Code (the `claude` CLI) isn't installed or isn't on the PATH."
            case .notAuthenticated:
                return "Claude Code isn't logged in. Run `claude` once in a terminal to sign in."
            case .timedOut:
                return "Claude took too long to respond."
            case .failed(let message):
                return message.isEmpty ? "Claude Code failed." : message
            case .emptyResponse:
                return "Claude returned an empty response."
            case .unparseableJSON(let text):
                return "Couldn't read Claude's reply as JSON:\n\(text.prefix(400))"
            }
        }
    }

    /// The wrapper `--output-format json` prints on stdout.
    private struct Envelope: Decodable {
        let isError: Bool?
        let subtype: String?
        let result: String?
        enum CodingKeys: String, CodingKey { case isError = "is_error", subtype, result }
    }

    /// Resolves the CLI (well-known dirs → PATH → login shell). nil if Claude Code isn't installed.
    static func detect() async -> ClaudeCodeCLI? {
        guard let url = await ClaudeCodeToolchain.resolveBinaryURL() else { return nil }
        return ClaudeCodeCLI(binary: url)
    }

    /// Sends `system` + `user`, returns the assistant's raw text (expected to be a JSON object).
    func complete(system: String, user: String, timeout: TimeInterval = 120) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw CLIError.notInstalled }

        var args = ["-p", user, "--system-prompt", system, "--output-format", "json"]
        if let model { args += ["--model", model] }

        let env = ClaudeCodeToolchain.environment(for: binary)
        let cwd = FileManager.default.temporaryDirectory   // neutral: no project context

        let result: CommandRunner.Result
        do {
            result = try await CommandRunner.run(binary, args, environment: env, currentDirectory: cwd, timeout: timeout)
        } catch {
            throw CLIError.failed(error.localizedDescription)
        }

        // Auth failures and crashes usually surface on stderr / a non-zero exit.
        if let envelope = decodeEnvelope(result.stdout) {
            if envelope.isError == true { throw CLIError.failed(envelope.result ?? "Claude reported an error.") }
            guard let text = envelope.result?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw CLIError.emptyResponse
            }
            return text
        }

        let stderr = result.stderr.lowercased()
        if stderr.contains("not logged in") || stderr.contains("authenticat") || stderr.contains("/login") {
            throw CLIError.notAuthenticated
        }
        if result.exitCode != 0 {
            throw CLIError.failed(result.stderr.isEmpty ? "claude exited with code \(result.exitCode)." : result.stderr)
        }
        throw CLIError.failed("claude returned no parseable output.")
    }

    /// Convenience: `complete` + decode the reply into `T`, tolerating ```json fences / prose.
    func suggest<T: Decodable>(_ type: T.Type, system: String, user: String,
                               timeout: TimeInterval = 120) async throws -> T {
        let text = try await complete(system: system, user: user, timeout: timeout)
        guard let data = ClaudeJSON.extractObject(from: text) else { throw CLIError.unparseableJSON(text) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CLIError.unparseableJSON(text) }
    }

    private func decodeEnvelope(_ stdout: String) -> Envelope? {
        guard let data = stdout.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Envelope.self, from: data)
    }
}

/// Extracts the first balanced top-level JSON object out of model text, ignoring ```json fences,
/// leading prose, and braces that appear inside strings. Pure → unit-tested.
enum ClaudeJSON {
    static func extractObject(from text: String) -> Data? {
        let chars = Array(text)
        var depth = 0
        var start: Int?
        var inString = false
        var escaped = false
        for (i, c) in chars.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{":
                if depth == 0 { start = i }
                depth += 1
            case "}":
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let s = start { return String(chars[s...i]).data(using: .utf8) }
                }
            default: break
            }
        }
        return nil
    }
}
