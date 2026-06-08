import XCTest
@testable import Jaca

/// Live checks against a booted iOS simulator. Skipped when no full Xcode or no
/// booted simulator is present.
final class LiveSimulatorTests: XCTestCase {
    func testDiscoversBootedSimulatorAndStreams() async throws {
        try XCTSkipUnless(AppleToolchain.hasFullXcode, "no full Xcode")

        let provider = SimulatorDeviceProvider(pollInterval: .milliseconds(500))
        let devices = await firstNonEmpty(provider.deviceStream(), timeout: .seconds(8))
        try XCTSkipIf(devices.isEmpty, "no booted simulator")

        let sim = try XCTUnwrap(devices.first)
        XCTAssertEqual(sim.platform, .iosSimulator)

        let source = SimulatorLogSource(udid: sim.id)
        let lines = await collect(try source.start(), max: 3, timeout: .seconds(12))
        source.stop()
        XCTAssertFalse(lines.isEmpty, "expected simulator log lines")
    }

    private func firstNonEmpty(_ stream: AsyncStream<[Device]>, timeout: Duration) async -> [Device] {
        await withTaskGroup(of: [Device]?.self) { group in
            group.addTask {
                for await list in stream where !list.isEmpty { return list }
                return nil
            }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let r = (await group.next()) ?? nil
            group.cancelAll()
            return r ?? []
        }
    }

    private func collect(_ stream: AsyncStream<LogLine>, max: Int, timeout: Duration) async -> [LogLine] {
        await withTaskGroup(of: [LogLine]?.self) { group in
            group.addTask {
                var out: [LogLine] = []
                for await line in stream { out.append(line); if out.count >= max { break } }
                return out
            }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let r = (await group.next()) ?? nil
            group.cancelAll()
            return r ?? []
        }
    }
}
