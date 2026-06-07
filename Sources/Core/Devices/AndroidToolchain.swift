import Foundation

/// Locates the `adb` binary. Resolution order:
/// Settings override → $ANDROID_HOME → $ANDROID_SDK_ROOT →
/// ~/Library/Android/sdk → `which adb`.
enum AndroidToolchain {
    static func adbURL(override: String? = nil) -> URL? {
        var candidates: [String] = []

        if let override, !override.isEmpty {
            candidates.append(override)
        }
        let env = ProcessInfo.processInfo.environment
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = env[key], !root.isEmpty {
                candidates.append("\(root)/platform-tools/adb")
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append("\(home)/Library/Android/sdk/platform-tools/adb")

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return whichADB()
    }

    /// Falls back to `/usr/bin/which adb` so a PATH install is found too.
    private static func whichADB() -> URL? {
        let which = URL(fileURLWithPath: "/usr/bin/which")
        guard FileManager.default.isExecutableFile(atPath: which.path) else { return nil }
        let process = Process()
        process.executableURL = which
        process.arguments = ["adb"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
