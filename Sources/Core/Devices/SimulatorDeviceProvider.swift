import Foundation

/// Parses `xcrun simctl list -j devices` JSON into booted simulators.
enum SimulatorDeviceParser {
    /// Returns booted simulators (the ones we can stream from).
    static func parseBooted(_ data: Data) -> [Device] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["devices"] as? [String: Any] else { return [] }

        var out: [Device] = []
        for (_, value) in devices {
            guard let list = value as? [[String: Any]] else { continue }
            for entry in list {
                let state = entry["state"] as? String ?? ""
                guard state == "Booted",
                      let udid = entry["udid"] as? String,
                      let name = entry["name"] as? String else { continue }
                out.append(Device(id: udid, platform: .iosSimulator, model: name, state: .booted))
            }
        }
        return out.sorted { $0.model < $1.model }
    }
}

/// Discovers booted iOS simulators by polling `simctl list -j devices`.
final class SimulatorDeviceProvider: DeviceProvider {
    let platform: DevicePlatform = .iosSimulator
    private let pollInterval: Duration

    init(pollInterval: Duration = .seconds(2)) {
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
        guard let result = try? await CommandRunner.run(
            AppleToolchain.xcrun, ["simctl", "list", "-j", "devices"],
            environment: AppleToolchain.environment()
        ) else { return [] }
        return SimulatorDeviceParser.parseBooted(Data(result.stdout.utf8))
    }
}
