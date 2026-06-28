import SwiftUI

/// The regex-helper affordance shown next to a query-builder value field when it's in regex mode:
/// the user describes what they want to match and Claude writes the RE2 pattern into the field.
/// Thin glue over the generic Ask-Claude window — only the use case is regex-specific.
struct CloudRegexAssistantButton: View {
    @Binding var value: String
    /// What's being matched (e.g. `labels.platform` or "the log message"), for the system prompt.
    let field: String

    var body: some View {
        ClaudeAskButton(label: "Regex",
                        help: "Describe what to match; Claude writes the regex",
                        useCase: useCase)
    }

    private var useCase: ClaudeUseCase<CloudRegexAssistant.Suggestion> {
        let field = field
        let binding = $value
        return ClaudeUseCase(
            title: "Ask Claude for a regex",
            inputPlaceholder: "e.g. a number starting 202606 then two digits > 27 then any digit",
            examples: [
                "a UUID",
                "an email address",
                "starts with 202606, then 2 digits > 27, then a digit",
                "only ERROR or WARNING",
            ],
            buildSystemPrompt: { CloudRegexAssistant.systemPrompt(field: field) },
            preview: { $0.regex },
            explanation: { $0.explanation },
            apply: { binding.wrappedValue = $0.regex }
        )
    }
}
