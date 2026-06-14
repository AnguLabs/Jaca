import Foundation

/// Installs and launches the "Jaca Setup Helper" companion app on the device — a
/// tiny on-screen guide (tutorial video + an "Open security settings" button) so
/// the CA-install steps appear right where the user is looking. Returns false when
/// the helper APK isn't bundled, so callers fall back to deep-linking Settings.
enum OnDeviceGuide {
    static let packageName = "dev.srsouza.jaca.setup"

    /// The bundled companion APK, or the dev build output when running unbundled.
    static var apkURL: URL? {
        if let u = Bundle.main.url(forResource: "jaca-setup-helper", withExtension: "apk",
                                   subdirectory: "companion") { return u }
        let dev = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("workspace/jaca/companion/out/jaca-setup-helper.apk")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    /// Installs (idempotent) and launches the helper on `serial`. Returns whether it
    /// launched, so the caller can fall back to a plain Settings deep-link.
    @discardableResult
    static func show(adbURL: URL, serial: String) async -> Bool {
        guard let apk = apkURL else { return false }
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "install", "-r", apk.path])
        let r = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "am", "start",
            "-n", "\(packageName)/.MainActivity"])
        let out = ((r?.stdout ?? "") + (r?.stderr ?? "")).lowercased()
        return r?.exitCode == 0 && !out.contains("error")
    }
}
