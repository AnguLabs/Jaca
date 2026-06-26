import XCTest
@testable import Jaca

/// End-to-end tests that drive the app's real session types the way the UI does
/// (NetworkSession's agent/proxy orchestration, AppModel logcat with filters),
/// not just the underlying components. Live tests skip when devices are absent.
@MainActor
final class AppLevelE2ETests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return cond()
    }

    private func curl(throughProxyPort port: Int, caPath: String, url: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "20",
                       "-x", "http://127.0.0.1:\(port)", "--cacert", caPath, url]
        let out = Pipe(); p.standardOutput = out
        try? p.run()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - clear() resets the timeline window (no device needed)

    func testClearResetsTimeRange() throws {
        let ca = try XCTUnwrap(try? CertificateAuthority())
        let device = Device(id: "test-host", platform: .android, model: "Test", state: .connected)
        let session = NetworkSession(device: device, ca: ca, adbURL: nil)
        let now = Date()
        session.selectedTimeRange = now...now.addingTimeInterval(5)
        session.selectedID = UUID()
        session.clear()
        XCTAssertNil(session.selectedTimeRange, "clear() must reset the timeline selection")
        XCTAssertNil(session.selectedID)
        XCTAssertTrue(session.transactions.isEmpty)
    }

    // MARK: - NetworkSession agent mode (debuggable Android app, no proxy/CA)

    func testNetworkSessionAgentModeLive() async throws {
        let adb = try XCTUnwrap(AndroidToolchain.adbURL(), "adb not found")
        let serial = "emulator-5554"
        let pkg = "com.example.app.dev"
        let devices = try? await CommandRunner.run(adb, ["devices"])
        try XCTSkipUnless(devices?.stdout.contains(serial) == true, "no emulator")
        try XCTSkipUnless(AgentArtifacts.isAvailable, "agent artifacts not built")
        let debuggable = await AgentController.isDebuggable(adbURL: adb, serial: serial, package: pkg)
        try XCTSkipUnless(debuggable, "test app not present/debuggable")

        // Fresh process so the attach lands on a stable pid.
        _ = try? await CommandRunner.run(adb, ["-s", serial, "shell", "am", "force-stop", pkg])
        _ = try? await CommandRunner.run(adb, ["-s", serial, "shell", "am", "start", "-n", "\(pkg)/com.example.app.MainActivity"])
        var up = false
        for _ in 0..<8 {
            let p = (try? await CommandRunner.run(adb, ["-s", serial, "shell", "pidof", pkg]))?.stdout ?? ""
            if !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { up = true; break }
            try await Task.sleep(for: .seconds(1))
        }
        try XCTSkipUnless(up, "could not launch \(pkg)")

        let ca = try XCTUnwrap(try? CertificateAuthority())
        let device = Device(id: serial, platform: .android, model: "Emulator", state: .connected)
        let session = NetworkSession(device: device, ca: ca, adbURL: adb)
        session.startAgentCapture(package: pkg)   // explicit in-process agent mode
        let agentChosen = await waitUntil(10) { session.captureMode == .agent }
        XCTAssertTrue(agentChosen, "explicit agent mode should capture in-process")

        // Pipeline connected (status) and/or a transaction with a call stack.
        let ok = await waitUntil(25) {
            session.statusMessage?.contains("receiving") == true || !session.transactions.isEmpty
        }
        session.stop()
        XCTAssertTrue(ok, "agent session did not connect (status: \(session.statusMessage ?? "nil"))")
        if let t = session.transactions.first { XCTAssertNotNil(t.callStack) }
    }

    // MARK: - Logcat package filter resolves live PIDs (Android)

    func testLogcatPackagePidResolutionLive() async throws {
        setenv("JACA_UITEST", "1", 1)
        defer { unsetenv("JACA_UITEST") }
        let adb = try XCTUnwrap(AndroidToolchain.adbURL(), "adb not found")
        let model = AppModel()
        model.startDiscovery()
        let got = await waitUntil(10) { model.devices.contains { $0.platform == .android && $0.state.isReady } }
        try XCTSkipUnless(got, "no ready Android device")
        let device = model.devices.first { $0.platform == .android && $0.state.isReady }!
        _ = adb

        let session = try XCTUnwrap(model.startSession(for: device))
        _ = await waitUntil(10) { session.totalCount > 0 }
        session.setPackage("com.android.systemui")  // always running
        let resolved = await waitUntil(6) { (session.filter.pids?.isEmpty == false) }
        XCTAssertTrue(resolved, "package filter did not resolve PIDs")
        model.closeSession(session.id)
    }
}
