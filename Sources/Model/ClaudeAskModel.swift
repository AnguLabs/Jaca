import Foundation
import Observation

/// A reusable "Ask Claude" use case: everything that makes one Claude window specific to a place
/// in the app, decoupled from the engine (`ClaudeCodeCLI`) and the UI (`ClaudeAskSheet`). Each
/// feature defines one of these (e.g. the Cloud Logging SQL filter); the model + window are shared.
///
/// Layering: `ClaudeCodeCLI` (engine) ← `ClaudeUseCase` / `ClaudeAskModel` (generic) ← a feature.
struct ClaudeUseCase<Output: Decodable & Sendable> {
    /// Window title, e.g. "Ask Claude for a SQL filter".
    let title: String
    /// Placeholder for the request field.
    let inputPlaceholder: String
    /// Quick starter prompts shown as chips.
    let examples: [String]
    /// Builds the system prompt (the format contract + live context). Async so it can read the DB.
    let buildSystemPrompt: @MainActor () async -> String
    /// The text to show as the result body (e.g. the generated SQL).
    let preview: (Output) -> String
    /// An optional one-line description shown above the preview.
    let explanation: (Output) -> String?
    /// Applies the accepted result to the app (e.g. set the SQL and run it).
    let apply: @MainActor (Output) -> Void
}

/// Drives one Ask-Claude window for any `ClaudeUseCase`: holds the request, runs the `claude` CLI
/// with the use case's system prompt, exposes the decoded result, and applies it on accept.
/// Generic over the use case's `Output` so the same model/UI serve every place Claude is offered.
@MainActor
@Observable
final class ClaudeAskModel<Output: Decodable & Sendable> {
    var input = ""
    private(set) var isRunning = false
    private(set) var output: Output?
    private(set) var errorMessage: String?
    /// nil while detecting; false → Claude Code isn't installed (the UI shows guidance).
    private(set) var available: Bool?

    let useCase: ClaudeUseCase<Output>
    private var cli: ClaudeCodeCLI?
    private var task: Task<Void, Never>?

    init(useCase: ClaudeUseCase<Output>) {
        self.useCase = useCase
        Task { [weak self] in
            let detected = await ClaudeCodeCLI.detect()
            guard let self else { return }
            self.cli = detected
            self.available = (detected != nil)
        }
    }

    var canSubmit: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRunning && available != false
    }

    func use(example: String) { input = example }

    func submit() {
        let request = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isRunning else { return }
        guard let cli else {
            errorMessage = ClaudeCodeCLI.CLIError.notInstalled.errorDescription
            return
        }
        isRunning = true
        errorMessage = nil
        output = nil
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let system = await self.useCase.buildSystemPrompt()
            do {
                let result = try await cli.suggest(Output.self, system: system, user: request)
                if Task.isCancelled { return }
                self.output = result
            } catch {
                if Task.isCancelled { return }
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            self.isRunning = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// Applies the current result to the app via the use case.
    func apply() {
        guard let output else { return }
        useCase.apply(output)
    }
}
