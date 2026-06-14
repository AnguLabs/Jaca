import Foundation

/// Version reconciliation for the companion app. The APK Jaca ships records the git commit
/// it was built from (scripts/build-mobile.sh writes it both into the APK's BuildConfig and
/// a sidecar next to the bundled APK). A connected device reports its own build commit over
/// gRPC (DeviceInfo.version); comparing the two tells us when a device is running an older
/// companion build and should be re-installed.
enum CompanionVersion {
    /// Commit hash of the APK Jaca bundles, or nil for dev builds with no bundled APK.
    static let bundled: String? = {
        guard let url = Bundle.main.url(forResource: "jaca-mobile.apk", withExtension: "version"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }()

    /// Whether a device reporting `deviceVersion` should be prompted to update. False when
    /// we have nothing to compare against (dev build on either side) so we never nag.
    static func updateAvailable(deviceVersion: String) -> Bool {
        guard let bundled, !deviceVersion.isEmpty, deviceVersion != "dev" else { return false }
        return deviceVersion != bundled
    }
}
