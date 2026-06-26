import XCTest
@testable import Jaca

@MainActor
final class LogMarkerTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return cond()
    }

    /// The reported bug: filtering by a package, the app crashes → all logs vanish.
    /// Now: logs stay, and a death/restart marker is injected.
    func testAppDeathKeepsLogsAndMarksDeathAndRestart() async throws {
        let adb = try XCTUnwrap(AndroidToolchain.adbURL(), "adb not found")
        let serial = "emulator-5554", pkg = "com.example.app.dev"
        let devices = try? await CommandRunner.run(adb, ["devices"])
        try XCTSkipUnless(devices?.stdout.contains(serial) == true, "no emulator")

        func launch() async { _ = try? await CommandRunner.run(adb, ["-s", serial, "shell", "am", "start", "-n", "\(pkg)/com.example.app.MainActivity"]) }
        await launch()

        let model = AppModel()
        model.startDiscovery()
        let ready = await waitUntil(10) { model.devices.contains { $0.id == serial && $0.state.isReady } }
        try XCTSkipUnless(ready, "device not ready")
        let device = model.devices.first { $0.id == serial }!

        let session = try XCTUnwrap(model.startSession(for: device))
        session.setPackage(pkg)

        // Wait until we're following the app (PIDs resolved + its logs visible).
        let following = await waitUntil(15) { (session.filter.pids?.isEmpty == false) && session.visible.count > 0 }
        try XCTSkipUnless(following, "app produced no logs to follow")
        let countBeforeDeath = session.visible.count

        // Kill the app → logs MUST remain + a terminated marker appears.
        _ = try? await CommandRunner.run(adb, ["-s", serial, "shell", "am", "force-stop", pkg])
        let terminated = await waitUntil(8) {
            session.visible.contains { $0.isMarker && $0.message.contains("terminated") }
        }
        XCTAssertTrue(terminated, "no 'terminated' marker after the app was killed")
        XCTAssertGreaterThanOrEqual(session.visible.count, countBeforeDeath,
                                    "logs were cleared when the app died — the bug")

        // Relaunch → restarted marker + new pid picked up.
        await launch()
        let restarted = await waitUntil(15) {
            session.visible.contains { $0.isMarker && $0.message.contains("restarted") }
        }
        XCTAssertTrue(restarted, "no 'restarted' marker after relaunch")

        model.closeSession(session.id)
    }
}
