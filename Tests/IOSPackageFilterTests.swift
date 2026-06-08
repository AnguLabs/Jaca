import XCTest
@testable import Jaca

@MainActor
final class IOSPackageFilterTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return cond()
    }

    /// The connect gate must recognize a booted simulator even when the Android SDK
    /// is installed (it previously ran `simctl` via the adb path and failed).
    func testSimulatorConnectGatePassesWithAndroidSDKPresent() async throws {
        let model = AppModel()
        model.startDiscovery()
        let ready = await waitUntil(12) { model.devices.contains { $0.platform == .iosSimulator && $0.state.isReady } }
        try XCTSkipUnless(ready, "no booted simulator")
        let sim = model.devices.first { $0.platform == .iosSimulator && $0.state.isReady }!

        let session = try XCTUnwrap(model.startSession(for: sim, autoStart: false))
        session.connect()
        let settled = await waitUntil(8) { !session.isConnecting }
        XCTAssertTrue(settled, "connect() never settled")
        XCTAssertTrue(session.isRunning,
                      "booted simulator should connect (status: \(session.statusMessage ?? "nil"))")
        XCTAssertNotEqual(session.statusMessage?.contains("isn’t booted"), true)
        model.closeSession(session.id)
    }

    /// Filtering an iOS-simulator session by a bundle id must show that app's logs.
    /// (The bug: we matched the bundle id against the process name, which is the
    /// executable — "Teya Dev" — so nothing matched. Now we filter by the resolved pid.)
    func testSimulatorPackageFilterShowsAppLogsViaPID() async throws {
        let model = AppModel()
        model.startDiscovery()
        let ready = await waitUntil(12) { model.devices.contains { $0.platform == .iosSimulator && $0.state.isReady } }
        try XCTSkipUnless(ready, "no booted simulator")
        let sim = model.devices.first { $0.platform == .iosSimulator && $0.state.isReady }!
        let pkg = "com.teya.ac.dev"

        // Make sure the app is running so it has a pid + emits logs.
        _ = try? await CommandRunner.run(AppleToolchain.xcrun, ["simctl", "launch", sim.id, pkg])
        try await Task.sleep(for: .seconds(2))
        let pids = await SimulatorLogSource.resolvePIDs(udid: sim.id, bundleID: pkg)
        try XCTSkipUnless(!pids.isEmpty, "\(pkg) not installed/running on the simulator")

        let session = try XCTUnwrap(model.startSession(for: sim))
        session.setPackage(pkg)
        session.setHideSystemLogs(false)   // this test validates pid filtering, not the system-noise hide

        // The app's process logs continuously (incl. com.apple.network); filtered lines should appear.
        let got = await waitUntil(25) { session.visible.contains { !$0.isMarker } }
        XCTAssertTrue(got, "no logs shown for \(pkg) — the iOS pid filter isn't matching")
        if let line = session.visible.first(where: { !$0.isMarker }) {
            XCTAssertTrue(pids.contains(line.pid), "shown line pid \(line.pid) not in app pids \(pids)")
        }
        model.closeSession(session.id)
    }
}
