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

    /// Short label for the device row / tab subtitle, e.g. "Pixel 7".
    var displayModel: String { model.isEmpty ? id : model }
}
