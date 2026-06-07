import Foundation

/// Resolves the Apple developer toolchain for `xcrun simctl` / `devicectl`.
/// `xcode-select` may point at CommandLineTools (which lacks simctl), so we
/// resolve a real Xcode and pass it via `DEVELOPER_DIR` on every invocation.
enum AppleToolchain {
    static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    /// Path to a full Xcode's Developer dir, or nil if only CLT is present.
    static func developerDir() -> String? {
        // Honor an explicit env first.
        if let env = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
           FileManager.default.fileExists(atPath: "\(env)/usr/bin/simctl")
            || FileManager.default.fileExists(atPath: "\(env)/usr/bin/xcrun") {
            return env
        }
        // Common install location.
        let standard = "/Applications/Xcode.app/Contents/Developer"
        if FileManager.default.fileExists(atPath: standard) {
            return standard
        }
        // Whatever xcode-select points at (may be CLT — still usable for some tools).
        let active = "/Library/Developer/CommandLineTools"
        return FileManager.default.fileExists(atPath: active) ? active : nil
    }

    /// Environment for spawning xcrun with the resolved Xcode.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let dir = developerDir() { env["DEVELOPER_DIR"] = dir }
        return env
    }

    /// True when a full Xcode (with simctl) is available.
    static var hasFullXcode: Bool {
        guard let dir = developerDir() else { return false }
        return FileManager.default.fileExists(atPath: "\(dir)/usr/bin/simctl")
    }
}
