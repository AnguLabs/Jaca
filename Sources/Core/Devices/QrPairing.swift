import Foundation

/// The credentials encoded into a Wi-Fi-debugging pairing QR code. When the phone
/// scans the QR (Settings → Wireless debugging → *Pair device with QR code*), it
/// starts advertising an `_adb-tls-pairing._tcp` mDNS service whose **instance name
/// equals `serviceName`**, protected by `password`. We then spot that exact instance
/// over mDNS and run `adb pair <ip:port> <password>`.
///
/// Pure & Foundation-only so it's unit-testable. QR *image* rendering lives in the
/// view layer (CoreImage), keeping this side effect-free.
struct QrPairingCredentials: Sendable, Equatable {
    let serviceName: String
    let password: String

    /// The exact string the QR must encode. Android parses this as a Wi-Fi-style
    /// payload with type `ADB`. Format (from Android Studio): `WIFI:T:ADB;S:<name>;P:<pw>;;`
    var qrPayload: String { "WIFI:T:ADB;S:\(serviceName);P:\(password);;" }

    /// Generates fresh credentials. The phone advertises whatever name we pick, so the
    /// only requirements are uniqueness (to disambiguate our QR from other devices'
    /// pairing services) and that the password be hard to guess. We follow Studio's
    /// "studio-<random>" convention with a "jaca-" prefix.
    static func generate() -> QrPairingCredentials {
        QrPairingCredentials(
            serviceName: "jaca-" + randomString(length: 10, charset: alphanumeric),
            password: randomString(length: 12, charset: alphanumeric)
        )
    }

    // Avoid ';', ':' and other characters that have meaning in the payload grammar.
    private static let alphanumeric = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    private static func randomString(length: Int, charset: [Character]) -> String {
        String((0..<length).map { _ in charset.randomElement()! })
    }
}
