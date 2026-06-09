import Foundation

/// Detects the single header line that begins an Android app crash, so we count
/// once per crash (not once per stack-trace line).
enum CrashDetector {
    static func isCrash(_ line: LogLine) -> Bool {
        if line.isMarker { return false }
        // Java/Kotlin uncaught exception (the classic crash).
        if line.tag == "AndroidRuntime", line.message.contains("FATAL EXCEPTION") { return true }
        // Native crash (signal / tombstone).
        if line.tag == "libc", line.message.contains("Fatal signal") { return true }
        if line.message.hasPrefix("*** *** *** *** ***") { return true }
        return false
    }

    /// Short label for the inline crash marker.
    static func label(_ line: LogLine) -> String {
        if line.tag == "libc" || line.message.hasPrefix("***") { return "native crash" }
        // Pull the exception type if present: "FATAL EXCEPTION: main" → keep it short.
        if let range = line.message.range(of: "FATAL EXCEPTION") {
            return String(line.message[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
        }
        return "crash"
    }
}
