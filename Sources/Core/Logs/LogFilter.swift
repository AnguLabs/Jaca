import Foundation

/// Declarative filter applied to a session's log stream. Value type so the UI
/// can bind to it and the session recomputes the visible slice on change.
struct LogFilter: Sendable, Equatable {
    var minLevel: LogLevel = .verbose
    var query: String = ""              // free-text or regex over tag+message
    var isRegex: Bool = false
    var tagQuery: String = ""           // substring on tag only
    /// Resolved PIDs for the package filter (Android); `nil` means "all".
    var pids: Set<Int32>? = nil
    /// Process/subsystem substring filter (iOS, where there's no `pidof`).
    var processNameQuery: String = ""
    /// Human label of the package filter, for the tab subtitle (e.g. "com.foo").
    var packageLabel: String = ""

    var isEmpty: Bool {
        minLevel == .verbose && query.isEmpty && tagQuery.isEmpty
            && pids == nil && processNameQuery.isEmpty
    }

    /// Compiles `query` to a regex once (when `isRegex`), so `matches` stays cheap
    /// in the hot path. Returns nil if regex is off or the pattern is invalid.
    func compiledRegex() -> NSRegularExpression? {
        guard isRegex, !query.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: query, options: [.caseInsensitive])
    }

    /// Whether `line` passes the filter. Pass the precompiled `regex` from
    /// `compiledRegex()` to avoid recompiling per line.
    func matches(_ line: LogLine, regex: NSRegularExpression?) -> Bool {
        if line.isMarker { return true }   // Jaca markers are never filtered out
        if line.level < minLevel { return false }
        if let pids, !pids.contains(line.pid) { return false }
        if !processNameQuery.isEmpty {
            let process = line.processName ?? ""
            if process.range(of: processNameQuery, options: .caseInsensitive) == nil,
               line.tag.range(of: processNameQuery, options: .caseInsensitive) == nil {
                return false
            }
        }
        if !tagQuery.isEmpty,
           line.tag.range(of: tagQuery, options: .caseInsensitive) == nil {
            return false
        }
        if !query.isEmpty {
            if isRegex {
                guard let regex else { return false }  // invalid pattern → match nothing
                let haystack = line.tag + " " + line.message
                let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
                if regex.firstMatch(in: haystack, range: range) == nil { return false }
            } else {
                let inMessage = line.message.range(of: query, options: .caseInsensitive) != nil
                let inTag = line.tag.range(of: query, options: .caseInsensitive) != nil
                if !inMessage && !inTag { return false }
            }
        }
        return true
    }
}
