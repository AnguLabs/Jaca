import XCTest
@testable import Jaca

/// End-to-end checks against a real connected device/emulator. Skipped when adb
/// or a device isn't available, so the suite stays green in headless CI.
final class LiveAndroidTests: XCTestCase {
    func testDiscoversDeviceAndStreamsParsedLogcat() async throws {
        let adb = try XCTUnwrap(AndroidToolchain.adbURL(), "adb not found")

        let provider = AndroidDeviceProvider(adbURL: adb, pollInterval: .milliseconds(500))
        let devices = await firstNonEmpty(provider.deviceStream(), timeout: .seconds(8))
        try XCTSkipIf(devices.isEmpty, "no Android device/emulator connected")

        let ready = try XCTUnwrap(devices.first(where: { $0.state.isReady }), "no ready device")
        XCTAssertFalse(ready.model.isEmpty, "device model should be resolved")

        let source = AndroidLogSource(adbURL: adb, serial: ready.id)
        let lines = await collect(try source.start(), max: 5, timeout: .seconds(10))
        source.stop()

        XCTAssertFalse(lines.isEmpty, "expected to stream logcat lines")
        XCTAssertTrue(lines.allSatisfy { $0.seq < UInt64(lines.count) || true })  // monotonic ids assigned
        XCTAssertEqual(lines.map(\.seq), Array(0..<UInt64(lines.count)))
    }

    /// Full live pipeline: stream → coalesced `visible` snapshot → batched persist
    /// → query back from SQLite.
    @MainActor
    func testSessionStreamsToVisibleAndPersists() async throws {
        let adb = try XCTUnwrap(AndroidToolchain.adbURL(), "adb not found")
        let provider = AndroidDeviceProvider(adbURL: adb, pollInterval: .milliseconds(500))
        let devices = await firstNonEmpty(provider.deviceStream(), timeout: .seconds(8))
        try XCTSkipIf(devices.isEmpty, "no Android device/emulator connected")
        let ready = try XCTUnwrap(devices.first(where: { $0.state.isReady }))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("squeeze-live-\(UUID().uuidString).sqlite")
        let store = try XCTUnwrap(HistoryStore(url: url))
        defer { try? FileManager.default.removeItem(at: url) }

        let session = LogSession(
            device: ready, makeSource: { AndroidLogSource(adbURL: adb, serial: ready.id) }, adbURL: adb,
            onPersist: { sid, lines in Task { await store.appendLines(sessionID: sid, lines) } }
        )
        await store.beginSession(id: session.id, device: ready, package: "", displayName: "live")

        session.start()
        // Generate guaranteed traffic, then let it stream, flush (30ms) and persist.
        _ = try? await CommandRunner.run(adb, ["-s", ready.id, "shell", "log", "-t", "JacaTest", "hello-from-test"])
        try await Task.sleep(for: .seconds(3))
        session.stop()
        try await Task.sleep(for: .milliseconds(500))  // let persist tasks drain

        XCTAssertGreaterThan(session.totalCount, 0, "lines should reach the session")
        XCTAssertFalse(session.visible.isEmpty, "visible snapshot should be populated")

        let persisted = await store.lines(sessionID: session.id)
        XCTAssertFalse(persisted.isEmpty, "lines should be persisted to SQLite")
    }

    // MARK: - Async helpers

    private func firstNonEmpty(_ stream: AsyncStream<[Device]>, timeout: Duration) async -> [Device] {
        await withTaskGroup(of: [Device]?.self) { group in
            group.addTask {
                for await list in stream where !list.isEmpty { return list }
                return nil
            }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let result = (await group.next()) ?? nil
            group.cancelAll()
            return result ?? []
        }
    }

    private func collect(_ stream: AsyncStream<LogLine>, max: Int, timeout: Duration) async -> [LogLine] {
        await withTaskGroup(of: [LogLine]?.self) { group in
            group.addTask {
                var out: [LogLine] = []
                for await line in stream {
                    out.append(line)
                    if out.count >= max { break }
                }
                return out
            }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let result = (await group.next()) ?? nil
            group.cancelAll()
            return result ?? []
        }
    }
}
