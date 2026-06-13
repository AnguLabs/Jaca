import Foundation

/// A single running Gradle daemon process, as parsed from `ps`.
struct GradleDaemon: Identifiable, Hashable {
    var id: String { String(pid) }
    let pid: Int32
    var version: String       // e.g. "9.4.1" (or "?" if unparsed)
    var uptime: String        // friendly, e.g. "2h 14m"
    var cpu: Double           // percent
    var memoryMB: Int
    var jdk: String?          // major JDK version, e.g. "21" (nil if unknown)
    var maxHeap: String?      // JVM -Xmx value, e.g. "12g" (nil if unset)
    var removing: Bool = false

    /// Heuristic: a daemon burning CPU is mid-build; near-idle daemons sit ~0%.
    var isBusy: Bool { cpu > 20 }
}
