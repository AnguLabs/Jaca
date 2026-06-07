import Foundation

/// Parses `xcrun devicectl list devices --json-output` JSON into physical devices.
/// devicectl's schema has shifted across Xcode versions, so parsing is defensive.
enum IOSDeviceParser {
    static func parse(_ data: Data) -> [Device] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let result = root["result"] as? [String: Any]
        let list = (result?["devices"] as? [[String: Any]]) ?? (root["devices"] as? [[String: Any]]) ?? []

        var out: [Device] = []
        for entry in list {
            let hardware = entry["hardwareProperties"] as? [String: Any]
            let deviceProps = entry["deviceProperties"] as? [String: Any]
            let connection = entry["connectionProperties"] as? [String: Any]

            guard let udid = (hardware?["udid"] as? String) ?? (entry["identifier"] as? String) else { continue }
            let name = (deviceProps?["name"] as? String)
                ?? (hardware?["marketingName"] as? String)
                ?? (hardware?["productType"] as? String)
                ?? "iOS Device"
            let tunnel = (connection?["tunnelState"] as? String)?.lowercased()
            let state: DeviceState = (tunnel == "connected" || tunnel == "available") ? .connected : .offline

            out.append(Device(id: udid, platform: .iosDevice, model: name, state: state))
        }
        return out.sorted { $0.model < $1.model }
    }
}

/// Discovers physically-connected iOS devices via `devicectl` (Xcode 15+).
final class IOSDeviceProvider: DeviceProvider {
    let platform: DevicePlatform = .iosDevice
    private let pollInterval: Duration

    init(pollInterval: Duration = .seconds(4)) {
        self.pollInterval = pollInterval
    }

    func deviceStream() -> AsyncStream<[Device]> {
        AsyncStream { continuation in
            let task = Task { [pollInterval] in
                guard AppleToolchain.hasFullXcode else {
                    continuation.yield([]); continuation.finish(); return
                }
                var last: [Device]? = nil
                while !Task.isCancelled {
                    let devices = await Self.query()
                    if devices != last {
                        last = devices
                        continuation.yield(devices)
                    }
                    try? await Task.sleep(for: pollInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func query() async -> [Device] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("squeeze-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? await CommandRunner.run(
            AppleToolchain.xcrun,
            ["devicectl", "list", "devices", "--json-output", tmp.path],
            environment: AppleToolchain.environment()
        )) != nil, let data = try? Data(contentsOf: tmp) else { return [] }
        return IOSDeviceParser.parse(data)
    }
}
