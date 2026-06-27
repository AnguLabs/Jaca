import SwiftUI
import Lemonade

/// The Cloud Logging SQL use case for the generic Ask-Claude assistant: wires a session's schema +
/// live label examples into the system prompt and applies the suggested SQL back to the session.
/// This is the only SQL-specific glue — the window/model/engine are all shared. The gear opens the
/// per-label example-count config that feeds those examples.
struct CloudSqlAssistantButton: View {
    let session: CloudLogSession
    @State private var configuring = false

    var body: some View {
        HStack(spacing: 6) {
            ClaudeAskButton(label: "Ask Claude",
                            help: "Describe a filter in plain language; Claude writes the SQL",
                            useCase: Self.useCase(session: session))
            Button(action: { configuring = true }) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                    .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
            }
            .buttonStyle(.plain)
            .help("Configure how many example values per label are sent to Claude")
            .sheet(isPresented: $configuring) { CloudSqlLabelExamplesSheet(session: session) }
        }
    }

    /// Builds the SQL `ClaudeUseCase`. `static` + `[weak session]` so the captured closures don't
    /// retain the session beyond the window.
    static func useCase(session: CloudLogSession) -> ClaudeUseCase<CloudSqlAssistant.Suggestion> {
        ClaudeUseCase(
            title: "Ask Claude for a SQL filter",
            inputPlaceholder: "e.g. only errors for platform iOS in the last 30 minutes",
            examples: [
                "errors and warnings from the last hour",
                "only logs for platform iOS",
                "one line per user, most recent",
                "requests that took over 1s",
            ],
            buildSystemPrompt: { [weak session] in
                guard let session else { return "" }
                let samples = await session.labelSamples()
                return CloudSqlAssistant.systemPrompt(
                    logName: session.selectedLogName, samples: samples, currentSQL: session.sqlText)
            },
            preview: { $0.sql },
            explanation: { $0.explanation },
            apply: { [weak session] suggestion in session?.applySqlText(suggestion.sql) }
        )
    }
}
