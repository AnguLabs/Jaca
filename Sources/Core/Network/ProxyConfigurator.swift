import Foundation

/// Helpers to point a device at our proxy and to discover the host address the
/// device should use to reach it.
enum ProxyConfigurator {
    /// Host the device uses to reach this Mac: emulators use the magic 10.0.2.2;
    /// physical devices use the Mac's LAN IP.
    static func hostAddress(for device: Device) -> String {
        if device.platform == .android && device.id.hasPrefix("emulator-") {
            return "10.0.2.2"
        }
        return NetworkInterfaces.primaryIPv4() ?? "127.0.0.1"
    }

    static func setAndroidProxy(adbURL: URL, serial: String, host: String, port: Int) async {
        _ = try? await CommandRunner.run(
            adbURL, ["-s", serial, "shell", "settings", "put", "global", "http_proxy", "\(host):\(port)"]
        )
    }

    static func clearAndroidProxy(adbURL: URL, serial: String) async {
        _ = try? await CommandRunner.run(
            adbURL, ["-s", serial, "shell", "settings", "put", "global", "http_proxy", ":0"]
        )
    }

    /// Pushes the root CA to the device's shared storage for easy manual install.
    static func pushCACertToAndroid(adbURL: URL, serial: String, caPEM: URL) async -> Bool {
        let result = try? await CommandRunner.run(
            adbURL, ["-s", serial, "push", caPEM.path, "/sdcard/Download/SqueezeProxyCA.pem"]
        )
        return result?.exitCode == 0
    }
}

/// Resolves the Mac's primary non-loopback IPv4 address (for physical-device proxy).
enum NetworkInterfaces {
    static func primaryIPv4() -> String? {
        var address: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            let family = ptr.pointee.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: host)
            break
        }
        return address
    }
}
