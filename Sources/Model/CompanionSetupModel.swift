import Foundation
import AppKit
import Observation

/// Drives the "Connect a device" onboarding: runs a local web server hosting the Jaca
/// mobile APK + a QR code to it, installs over adb when a USB device is present, and
/// remembers the IP of any phone that fetches the APK so the hub auto-connects once the
/// companion app is running.
@Observable
@MainActor
final class CompanionSetupModel {
    var qr: NSImage?
    var connectURL: String = ""
    var adbDevices: [Device] = []
    var selectedSerial: String?
    var installStatus: String?
    var isInstalling = false
    var seenIPs: [String] = []

    private var server: CompanionWebServer?
    private let hub: CompanionHub
    private let adbURL: URL?
    /// Resolves the desktop's root CA PEM (lazily, so the CA is only minted when needed).
    private let caCertPEM: () -> String?

    init(hub: CompanionHub, adbURL: URL?, caCertPEM: @escaping () -> String? = { nil }) {
        self.hub = hub
        self.adbURL = adbURL
        self.caCertPEM = caCertPEM
    }

    func start() {
        guard server == nil else { return }
        let apk = Bundle.main.url(forResource: "jaca-mobile", withExtension: "apk")
        let s = CompanionWebServer(apkURL: apk, caCertPEM: caCertPEM)
        s.onClientSeen = { [weak self] ip in Task { @MainActor in self?.deviceSeen(ip) } }
        let port = s.start() ?? 8890
        server = s
        if let ip = LANAddress.current() {
            connectURL = "http://\(ip):\(port)/"
            qr = QRCode.image(connectURL)
        } else {
            connectURL = "Wi-Fi address unavailable — connect this Mac to Wi-Fi."
        }
        refreshAdbDevices()
    }

    func stop() { server?.stop(); server = nil }

    private func deviceSeen(_ ip: String) {
        if !seenIPs.contains(ip) { seenIPs.append(ip) }
        hub.rememberManual(host: ip)   // surfaces in the device list + auto-connects when up
    }

    func refreshAdbDevices() {
        guard let adb = adbURL else { return }
        Task {
            let r = try? await CommandRunner.run(adb, ["devices", "-l"])
            adbDevices = AndroidDeviceParser.parse(r?.stdout ?? "")
                .filter { $0.platform == .android && $0.state == .connected }
            if selectedSerial == nil || !adbDevices.contains(where: { $0.id == selectedSerial }) {
                selectedSerial = adbDevices.first?.id
            }
        }
    }

    /// Install the bundled APK over adb, then launch it so it starts advertising.
    func installApk() {
        guard !isInstalling else { return }
        guard let apk = Bundle.main.url(forResource: "jaca-mobile", withExtension: "apk") else {
            installStatus = "Bundled APK not found"; return
        }
        guard let adb = adbURL, let serial = selectedSerial ?? adbDevices.first?.id else {
            installStatus = "Connect a device via USB first"; return
        }
        isInstalling = true
        installStatus = "Installing on \(serial)…"
        Task {
            let r = try? await CommandRunner.run(adb, ["-s", serial, "install", "-r", apk.path])
            if r?.exitCode == 0 {
                _ = try? await CommandRunner.run(adb, ["-s", serial, "shell", "monkey", "-p",
                                                       "dev.srsouza.jaca", "-c",
                                                       "android.intent.category.LAUNCHER", "1"])
                installStatus = "Installed on \(serial) — open Jaca on the device and start capture."
            } else {
                installStatus = "Install failed: \(r?.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140) ?? "unknown error")"
            }
            isInstalling = false
        }
    }
}
