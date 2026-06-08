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

    func testConnectToMissingDeviceShowsClearError() async throws {
        let adb = try XCTUnwrap(AndroidToolchain.adbURL(), "adb not found")
        let device = Device(id: "no-such-device-zzz", platform: .android, model: "Ghost", state: .connected)
        let session = LogSession(device: device,
                                 makeSource: { AndroidLogSource(adbURL: adb, serial: device.id) },
                                 adbURL: adb)

        session.connect()
        let settled = await waitUntil(5) { !session.isConnecting }
        XCTAssertTrue(settled, "connect() never settled")
        XCTAssertFalse(session.isRunning, "should not start when the device is unavailable")
        let msg = try XCTUnwrap(session.statusMessage)
        XCTAssertTrue(msg.contains("isn’t connected"), "expected a clear message, got: \(msg)")
    }
}
