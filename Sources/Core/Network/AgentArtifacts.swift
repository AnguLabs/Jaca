import Foundation

/// How a network session is capturing traffic.
enum CaptureMode: Sendable, Equatable {
    case proxy
    case agent

    var label: String { self == .agent ? "in-process" : "proxy" }
}

/// Locates the bundled Android agent artifacts (native .so + dex). Falls back to
/// the dev build output (agent/out) when running unbundled from Xcode.
enum AgentArtifacts {
    /// Native agent for the given device ABI (default arm64-v8a).
    static func soURL(abi: String = "arm64-v8a") -> URL? {
        if let u = Bundle.main.url(forResource: "libsqueezeagent", withExtension: "so",
                                   subdirectory: "agent/\(abi)") { return u }
        return devPath("agent/out/\(abi)/libsqueezeagent.so")
    }

    static var dexURL: URL? {
        if let u = Bundle.main.url(forResource: "squeezeagent", withExtension: "dex",
                                   subdirectory: "agent") { return u }
        return devPath("agent/out/squeezeagent.dex")
    }

    static var isAvailable: Bool { soURL() != nil && dexURL != nil }

    private static func devPath(_ rel: String) -> URL? {
        let p = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("workspace/squeeze/\(rel)")
        return FileManager.default.fileExists(atPath: p.path) ? p : nil
    }
}
