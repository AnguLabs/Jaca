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
    /// executable — "Example Dev" — so nothing matched. Now we filter by the resolved pid.)
    func testSimulatorPackageFilterShowsAppLogsViaPID() async throws {
        let model = AppModel()
        model.startDiscovery()
        let ready = await waitUntil(12) { model.devices.contains { $0.platform == .iosSimulator && $0.state.isReady } }
        try XCTSkipUnless(ready, "no booted simulator")
        let sim = model.devices.first { $0.platform == .iosSimulator && $0.state.isReady }!
        let pkg = "com.example.app.dev"

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

        // Selecting a package on a simulator also starts stdout/print capture, which
        // (re)launches the app under a PTY — so the pre-resolved `pids` may be stale.
        // Re-resolve and assert every shown *OSLog* line belongs to the app's pid;
        // console (stdout/print) lines are app output by construction (they carry no
        // pid and are exempt from the pid filter), so they're allowed through.
        let livePids = pids.union(await SimulatorLogSource.resolvePIDs(udid: sim.id, bundleID: pkg))
        for line in session.visible where !line.isMarker && !line.isConsoleOutput {
            XCTAssertTrue(livePids.contains(line.pid),
                          "shown OSLog line pid \(line.pid) not in app pids \(livePids)")
        }
        model.closeSession(session.id)
    }
}
