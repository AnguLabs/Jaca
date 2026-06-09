import Foundation
import Observation

/// A single rule that hides log lines whose message matches `value`.
struct LogExcludeRule: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var value: String
    var mode: Mode = .prefix

    enum Mode: String, Codable, CaseIterable, Sendable {
        case prefix, contains
        var label: String { self == .prefix ? "Starts with" : "Contains" }
    }

    func excludes(_ message: String) -> Bool {
        guard !value.isEmpty else { return false }
        switch mode {
        case .prefix:   return message.hasPrefix(value)
        case .contains: return message.contains(value)
        }
    }
}

/// Global, persisted list of message patterns hidden from **every** log tab. Edited
/// in Settings and applied through each session's `LogFilter`, so the actual matching
/// stays a cheap value comparison (and thread-safe off the main actor).
@MainActor @Observable
final class LogExclusionStore {
    static let shared = LogExclusionStore()
    private static let key = "logExclusions"

    private(set) var rules: [LogExcludeRule]
    /// Invoked when the rules change so open sessions can re-filter.
    var onChange: (() -> Void)?

    /// Seeded on first launch; the user can edit or remove these.
    static let defaults: [LogExcludeRule] = [
        LogExcludeRule(value: "setRequestedFrameRate", mode: .prefix)
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([LogExcludeRule].self, from: data) {
            rules = saved
        } else {
            rules = Self.defaults
        }
    }

    func update(_ newRules: [LogExcludeRule]) {
        guard newRules != rules else { return }
        rules = newRules
        if let data = try? JSONEncoder().encode(newRules) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        onChange?()
    }
}
