import XCTest
@testable import Squeeze

/// Exercises full feature flows through the real models + live devices/proxy,
/// without depending on GUI window activation (which is flaky under automation).
@MainActor
final class AppModelIntegrationTests: XCTestCase {

    private func waitUntil(timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return cond()
    }

    /// Full logcat flow: discover → start session → stream → filter → persist → close.
    func testLogcatFullFlowLive() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(AndroidToolchain.adbURL() != nil, "adb not found")
        setenv("SQUEEZE_UITEST", "1", 1)   // isolate from restored tabs / persistence
        defer { unsetenv("SQUEEZE_UITEST") }
        let model = AppModel()
        model.startDiscovery()

        let gotDevice = await waitUntil(timeout: 10) {
            model.devices.contains { $0.platform == .android && $0.state.isReady }
        }
        try XCTSkipUnless(gotDevice, "no ready Android device")
        let device = model.devices.first { $0.platform == .android && $0.state.isReady }!

        let session = try XCTUnwrap(model.startSession(for: device), "startSession returned nil")
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertTrue(session.isRunning)

        let streamed = await waitUntil(timeout: 12) { session.totalCount > 0 }
        XCTAssertTrue(streamed, "expected streamed log lines")
        XCTAssertFalse(session.visible.isEmpty)

        // Level filter narrows the visible set.
        session.setMinLevel(.error)
        _ = await waitUntil(timeout: 2) { true }
        XCTAssertTrue(session.visible.allSatisfy { $0.level >= .error }, "min-level filter not applied")

        // Reset + text filter (no crash; matches are a subset).
        session.setMinLevel(.verbose)
        session.setQuery("zzz_nomatch_zzz")
        _ = await waitUntil(timeout: 1) { true }
        XCTAssertTrue(session.visible.allSatisfy { $0.message.contains("zzz_nomatch_zzz") || $0.tag.contains("zzz_nomatch_zzz") })

        // Clear empties the view.
        session.clear()
        XCTAssertEqual(session.visible.count, 0)

        model.closeSession(session.id)
        XCTAssertTrue(model.sessions.isEmpty)

        // History recorded the session.
        let sessions = await model.history?.sessions(deviceID: device.id) ?? []
        XCTAssertTrue(sessions.contains { $0.id == session.id.uuidString }, "session not persisted to history")
    }

    /// Full network flow: start a network tab (proxy) and capture a real HTTPS
    /// request routed through it with the generated CA trusted.
    func testNetworkCaptureLive() async throws {
        setenv("SQUEEZE_UITEST", "1", 1)            // skip mutating any real device proxy
        defer { unsetenv("SQUEEZE_UITEST") }

        let model = AppModel()
        let device = Device(id: "test-host", platform: .android, model: "Test", state: .connected)
        let session = try XCTUnwrap(model.startNetworkSession(for: device), "no CA / proxy")
        defer { session.stop() }

        let ready = await waitUntil(timeout: 5) { session.isRunning && session.boundPort > 0 }
        XCTAssertTrue(ready, "proxy didn't start")

        let caPath = session.ca.storageDirectory.appendingPathComponent("rootCA.pem").path
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "20",
                          "-x", "http://127.0.0.1:\(session.boundPort)", "--cacert", caPath,
                          "https://example.com/"]
        let out = Pipe(); curl.standardOutput = out
        try curl.run()
        let code = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        curl.waitUntilExit()
        try XCTSkipIf(code == "000" || code.isEmpty, "network unavailable")
        XCTAssertEqual(code, "200")

        let captured = await waitUntil(timeout: 4) {
            session.transactions.contains { $0.host.contains("example.com") && !$0.isInFlight }
        }
        XCTAssertTrue(captured, "transaction not captured by NetworkSession")
        let txn = session.transactions.first { $0.host.contains("example.com") }!
        XCTAssertEqual(txn.statusCode, 200)
        XCTAssertEqual(txn.scheme, "https")

        // HAR export of the captured traffic is well-formed.
        let har = try XCTUnwrap(HARExport.data(from: session.transactions))
        XCTAssertFalse(har.isEmpty)

        session.clear()
        XCTAssertTrue(session.transactions.isEmpty)
    }
}
