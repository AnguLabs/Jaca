import Foundation

/// Parses `adb devices -l` output into `Device`s. Pure & synchronous for testing.
enum AndroidDeviceParser {
    static func parse(_ output: String) -> [Device] {
        var devices: [Device] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("List of devices") { continue }
            if line.hasPrefix("*") { continue }            // "* daemon started …"
            if line.hasPrefix("adb:") { continue }

            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 2 else { continue }
            let serial = tokens[0]
            let state = mapState(tokens[1])

            var properties: [String: String] = [:]
            for token in tokens.dropFirst(2) where token.contains(":") {
                let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { properties[parts[0]] = parts[1] }
            }
            let model = (properties["model"] ?? properties["device"] ?? "")
                .replacingOccurrences(of: "_", with: " ")

            devices.append(Device(id: serial, platform: .android, model: model, state: state))
        }
        return devices.sorted { $0.id < $1.id }
    }

    private static func mapState(_ raw: String) -> DeviceState {
        switch raw {
        case "device": return .connected
        case "unauthorized": return .unauthorized
        case "offline": return .offline
        default: return .unknown
        }
    }
}

/// Discovers Android devices by polling `adb devices -l`, enriching missing model
/// names via `getprop`, and emitting the list whenever it changes.
final class AndroidDeviceProvider: DeviceProvider {
    let platform: DevicePlatform = .android
    private let adbURL: URL
    private let pollInterval: Duration

    init(adbURL: URL, pollInterval: Duration = .seconds(1)) {
        self.adbURL = adbURL
        self.pollInterval = pollInterval
    }

    func deviceStream() -> AsyncStream<[Device]> {
        AsyncStream { continuation in
            let task = Task { [adbURL, pollInterval] in
                var lastSnapshot: [Device]? = nil
                var modelCache: [String: String] = [:]
                while !Task.isCancelled {
                    var devices = await Self.queryDevices(adbURL: adbURL)
                    // Fill missing model names for ready devices via getprop (cached).
                    for index in devices.indices where devices[index].model.isEmpty && devices[index].state.isReady {
                        let serial = devices[index].id
                        if let cached = modelCache[serial] {
                            devices[index].model = cached
                        } else if let model = await Self.queryModel(adbURL: adbURL, serial: serial) {
                            modelCache[serial] = model
                            devices[index].model = model
                        }
                    }
                    if devices != lastSnapshot {
                        lastSnapshot = devices
                        continuation.yield(devices)
                    }
                    try? await Task.sleep(for: pollInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func queryDevices(adbURL: URL) async -> [Device] {
        guard let result = try? await CommandRunner.run(adbURL, ["devices", "-l"]) else { return [] }
        return AndroidDeviceParser.parse(result.stdout)
    }

    private static func queryModel(adbURL: URL, serial: String) async -> String? {
        guard let result = try? await CommandRunner.run(
            adbURL, ["-s", serial, "shell", "getprop", "ro.product.model"]
        ), result.exitCode == 0 else { return nil }
        let model = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : model
    }
}
