import Foundation

/// The "generate a regex from a plain-language description" use case for the Ask Claude feature,
/// used by the query builder's regex (`=~`) inputs. Cloud Logging's `=~` uses **RE2**, so the
/// system prompt constrains Claude to RE2 (no backreferences/lookaround) and explains how to
/// express numeric ranges (RE2 can't do arithmetic). Pure → unit-tested.
enum CloudRegexAssistant {
    /// What Claude must return (JSON only).
    struct Suggestion: Decodable, Sendable, Equatable {
        let regex: String
        let explanation: String?
    }

    /// Builds the system prompt. `field` describes what's being matched (e.g. `labels.platform`
    /// or "the log message (textPayload)") so Claude has context.
    static func systemPrompt(field: String) -> String {
        """
        You generate a single regular expression for a Google Cloud Logging filter. The user \
        describes, in plain language, what a value should match; you return exactly one regex.

        Respond with ONLY a JSON object, no prose and no markdown fences:
        {"regex": "<the regex pattern>", "explanation": "<one short sentence on what it matches>"}

        The regex is used with Cloud Logging's `=~` operator, which uses RE2 syntax:
        - Supported: character classes [...], anchors ^ $, quantifiers * + ? {m,n}, groups (...), \
        alternation |, non-capturing groups (?:...), and \\d \\w \\s etc.
        - NOT supported: backreferences and lookahead/lookbehind — never use them.
        - RE2 can't do arithmetic, so to match a numeric RANGE you must enumerate it with \
        alternation / character classes. For example a two-digit number greater than 27 (i.e. 28–99) \
        is (2[89]|[3-9]\\d); a value 0–255 is (25[0-5]|2[0-4]\\d|1?\\d?\\d).
        - Return ONLY the pattern — no surrounding quotes and no `=~`. By default `=~` matches a \
        substring; anchor with ^ and $ when the whole value must match.
        - Keep it as simple as correctness allows.

        The value being matched: \(field).
        """
    }

    /// Parses Claude's reply into a `Suggestion` (tolerating fences / surrounding prose).
    static func parse(_ text: String) -> Suggestion? {
        guard let data = ClaudeJSON.extractObject(from: text) else { return nil }
        return try? JSONDecoder().decode(Suggestion.self, from: data)
    }
}
