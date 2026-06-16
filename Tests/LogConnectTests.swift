import XCTest
@testable import Jaca

@MainActor
final class LogConnectTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return cond()
    }

    func testSetPackageTriggersImmediatePersist() {
        let device = Device(id: "dev", platform: .android, model: "M", state: .connected)
        let session = LogSession(device: device, makeSource: { _ in nil },
                                 adbURL: URL(fileURLWithPath: "/usr/bin/true"))
        var saves = 0
        session.onStateChanged = { saves += 1 }
        session.setPackage("com.example.app")
        XCTAssertGreaterThan(saves, 0, "changing the package must persist immediately")
        XCTAssertEqual(session.filter.packageLabel, "com.example.app")
        session.displayName = "Renamed"
        XCTAssertGreaterThanOrEqual(saves, 2, "rename must persist too")
    }

    func testConnectToMissingDeviceShowsClearError() async throws {
        let adb = try XCTUnwrap(AndroidToolchain.adbURL(), "adb not found")
        let device = Device(id: "no-such-device-zzz", platform: .android, model: "Ghost", state: .connected)
        let session = LogSession(device: device,
                                 makeSource: { _ in AndroidLogSource(adbURL: adb, serial: device.id) },
                                 adbURL: adb)

        session.connect()
        let settled = await waitUntil(5) { !session.isConnecting }
        XCTAssertTrue(settled, "connect() never settled")
        XCTAssertFalse(session.isRunning, "should not start when the device is unavailable")
        let msg = try XCTUnwrap(session.statusMessage)
        XCTAssertTrue(msg.contains("isn’t connected"), "expected a clear message, got: \(msg)")
    }
}
