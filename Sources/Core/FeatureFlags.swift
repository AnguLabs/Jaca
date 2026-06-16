import Foundation

/// Process-wide, persisted feature flags. Kept tiny and dependency-free so both `Core`
/// (e.g. `CaptureSourceRegistry`) and `Model`/`Features` can read the same value.
enum FeatureFlags {
    /// Companion + HTTPS decryption (CA install, device-wide capture). OFF by default and
    /// fully opt-in: when off, the companion subsystem is never started and network inspection
    /// offers only the in-process Agent. Experimental — see the Settings description.
    static let httpsDecryptionKey = "httpsDecryptionEnabled"
    static var httpsDecryptionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: httpsDecryptionKey) }
        set { UserDefaults.standard.set(newValue, forKey: httpsDecryptionKey) }
    }
}
