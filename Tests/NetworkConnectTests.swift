import XCTest
@testable import Jaca

@MainActor
final class NetworkConnectTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return cond()
    }

    func testAgentCaptureOnMissingDeviceShowsClearError() async throws {
        // Agent mode must reach the device to attach in-process; on a missing
        // device it should surface a clear message and not start. (Proxy mode, by
        // contrast, runs a local server regardless of device reachability.)
        let adb = try XCTUnwrap(AndroidToolchain.adbURL(), "adb not found")
        let ca = try XCTUnwrap(try? CertificateAuthority())
        let device = Device(id: "no-such-device-zzz", platform: .android, model: "Ghost", state: .connected)
        let session = NetworkSession(device: device, ca: ca, adbURL: adb)

        session.startAgentCapture(package: "com.example.missing")
        let settled = await waitUntil(5) { !session.isConnecting }
        XCTAssertTrue(settled, "startAgentCapture() never settled")
        XCTAssertFalse(session.isRunning, "should not start when the device is unavailable")
        let msg = try XCTUnwrap(session.statusMessage)
        XCTAssertTrue(msg.contains("isn’t connected"), "expected a clear message, got: \(msg)")
    }

    func testTargetPackagePersistsInDescriptorRoundTrip() throws {
        // The selected in-process app id must survive encode/decode of the tab list.
        let original = TabDescriptor(kind: .network, platform: .android, deviceID: "dev1",
                                     displayName: "Net", minLevel: 0, query: "",
                                     isRegex: false, packageLabel: "com.example.app.dev")
        let data = try JSONEncoder().encode([original])
        let restored = try JSONDecoder().decode([TabDescriptor].self, from: data)
        XCTAssertEqual(restored.first?.packageLabel, "com.example.app.dev")
        XCTAssertEqual(restored.first?.kind, .network)
    }

    func testCaptureModePersistsInDescriptorRoundTrip() throws {
        // The chosen capture mode must survive so a relaunched tab restores ready.
        let agent = TabDescriptor(kind: .network, platform: .android, deviceID: "dev1",
                                  displayName: "Net", minLevel: 0, query: "",
                                  isRegex: false, packageLabel: "com.example.app.dev", captureMode: "agent")
        let data = try JSONEncoder().encode([agent])
        XCTAssertEqual(try JSONDecoder().decode([TabDescriptor].self, from: data).first?.captureMode, "agent")
    }

    func testDescriptorDecodesLegacyDataWithoutCaptureMode() throws {
        // Tabs persisted before captureMode existed must still decode (→ nil ⇒ proxy).
        let legacy = """
        [{"kind":"network","platform":"android","deviceID":"d","displayName":"N",
          "minLevel":0,"query":"","isRegex":false,"packageLabel":""}]
        """
        let restored = try JSONDecoder().decode([TabDescriptor].self, from: Data(legacy.utf8))
        XCTAssertNil(restored.first?.captureMode)
    }
}
