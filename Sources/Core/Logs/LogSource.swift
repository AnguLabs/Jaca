import Foundation

/// A running log stream for one session. Implementations spawn the platform tool
/// (adb logcat, simctl log stream, …) and emit parsed `LogLine`s with monotonic
/// `seq`. The stream finishes when the process exits or `stop()` is called.
protocol LogSource: AnyObject, Sendable {
    func start() throws -> AsyncStream<LogLine>
    func stop()
}
