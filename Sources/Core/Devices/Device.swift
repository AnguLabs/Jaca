import Foundation

/// Which backend a device is reached through. The log/network source layer keys
/// off this so new platforms slot in without touching the UI.
enum DevicePlatform: String, Sendable, Hashable, Codable {
    case android
    case iosSimulator
    case iosDevice

    var displayName: String {
        switch self {
        case .android: return "Android"
        case .iosSimulator: return "iOS Simulator"
        case .iosDevice: return "iOS Device"
        }
    }
}

/// Connection readiness of a discovered device.
enum DeviceState: String, Sendable, Hashable, Codable {
    case connected      // android: "device" / ready to stream
    case unauthorized   // android: needs USB-debugging authorization
    case offline        // android: present but not responsive
    case booted         // ios simulator booted
    case shutdown       // ios simulator not booted
    case unknown

    /// Whether we can start a log stream against it right now.
    var isReady: Bool { self == .connected || self == .booted }

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .unauthorized: return "Unauthorized"
        case .offline: return "Offline"
        case .booted: return "Booted"
        case .shutdown: return "Shutdown"
        case .unknown: return "Unknown"
        }
    }
}

/// A connected device/emulator/simulator discovered by a `DeviceProvider`.
/// `id` is the stable serial (Android) or UDID (iOS) used for `-s`/`--udid`.
struct Device: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let platform: DevicePlatform
    var model: String
    var state: DeviceState

    /// Reachable only via the companion mDNS stream (no USB/ADB) — shown in its own
    /// list section rather than as an adb device.
    var isCompanion: Bool = false
    /// The companion advertisement id, set when a Jaca mobile agent is reachable for
    /// this device (whether it's also an adb device or companion-only). Enables the
    /// companion capture source and the device-list chip. nil = no companion.
    var companionID: String?
    /// Whether the companion stream is currently connected (chip: green vs red).
    var companionConnected: Bool = false
    /// The companion app on this device is older than the APK Jaca bundles (commit hash
    /// mismatch) — prompt the user to update it.
    var companionUpdateAvailable: Bool = false

    /// Short label for the device row / tab subtitle, e.g. "Pixel 7".
    var displayModel: String { model.isEmpty ? id : model }

    /// Companion fields are runtime/discovery state, not persisted — keep them out of
    /// Codable so older persisted devices still decode and history stays stable.
    private enum CodingKeys: String, CodingKey { case id, platform, model, state }
}
