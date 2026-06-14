import Foundation

/// Device-wide MITM proxy capture. Runs a local proxy server and, on a reachable
/// Android device, points the device's HTTP proxy at it while running (reverting on
/// stop). Owns the whole device-proxy lifecycle so NetworkSession stays generic.
@MainActor
final class ProxyCaptureSource: CaptureSource {
    private let device: Device
    private let ca: CertificateAuthority
    private let adbURL: URL?
    private var server: ProxyServer?
    private(set) var isProxyConfigured = false

    init(device: Device, ca: CertificateAuthority, adbURL: URL?) {
        self.device = device
        self.ca = ca
        self.adbURL = adbURL
    }

    func start(into sink: CaptureSink) {
        let server = ProxyServer(port: 0, ca: ca) { [weak sink] txn in
            Task { @MainActor in sink?.capture(didReceive: txn) }
        }
        do {
            try server.start()
            self.server = server
            sink.capture(didBindPort: server.boundPort)
            configureDeviceProxy(port: server.boundPort)
            let host = ProxyConfigurator.hostAddress(for: device)
            sink.capture(didChangeStatus: "proxy on \(host):\(server.boundPort) — install the CA & trust it")
            if device.platform == .android, ProcessInfo.processInfo.environment["JACA_UITEST"] != "1" {
                sink.captureNeedsSetup()
            }
        } catch {
            sink.capture(didChangeStatus: "Failed to start proxy: \(error.localizedDescription)")
        }
    }

    func stop() {
        unconfigureDeviceProxy()
        server?.stop()
        server = nil
    }

    private func configureDeviceProxy(port: Int) {
        if ProcessInfo.processInfo.environment["JACA_UITEST"] == "1" { return }
        guard device.platform == .android, let adbURL else { return }
        let serial = device.id, host = ProxyConfigurator.hostAddress(for: device)
        // Arm the global cleanup registry first, so a crash/kill before stop() still reverts.
        ProxyCleanup.register(adbPath: adbURL.path, serial: serial)
        isProxyConfigured = true
        Task { await ProxyConfigurator.setAndroidProxy(adbURL: adbURL, serial: serial, host: host, port: port) }
    }

    private func unconfigureDeviceProxy() {
        guard device.platform == .android, let adbURL, isProxyConfigured else { return }
        let serial = device.id
        isProxyConfigured = false
        ProxyCleanup.deregister(adbPath: adbURL.path, serial: serial)
        Task { await ProxyConfigurator.clearAndroidProxy(adbURL: adbURL, serial: serial) }
    }
}
