import XCTest
@testable import Jaca

final class CrashDetectorTests: XCTestCase {
    private func line(tag: String, _ msg: String, level: LogLevel = .error) -> LogLine {
        LogLine(seq: 0, timestamp: Date(), level: level, tag: tag, pid: 1, tid: 0, message: msg, raw: msg)
    }

    func testDetectsFatalException() {
        XCTAssertTrue(CrashDetector.isCrash(line(tag: "AndroidRuntime", "FATAL EXCEPTION: main")))
    }
    func testDetectsNativeFatalSignal() {
        XCTAssertTrue(CrashDetector.isCrash(line(tag: "libc", "Fatal signal 11 (SIGSEGV)")))
    }
    func testIgnoresStackFramesAndPlainErrors() {
        XCTAssertFalse(CrashDetector.isCrash(line(tag: "AndroidRuntime", "\tat com.foo.Bar(Bar.kt:10)")))
        XCTAssertFalse(CrashDetector.isCrash(line(tag: "MyApp", "some error happened")))
    }
    func testIgnoresMarkers() {
        XCTAssertFalse(CrashDetector.isCrash(.marker("💥 crash", critical: true)))
    }
    func testLabelIncludesException() {
        XCTAssertTrue(CrashDetector.label(line(tag: "AndroidRuntime", "FATAL EXCEPTION: main")).contains("FATAL EXCEPTION"))
        XCTAssertEqual(CrashDetector.label(line(tag: "libc", "Fatal signal 11")), "native crash")
    }
}

/// Live: inject a fake crash line via `adb log` and confirm the counter + marker.
@MainActor
final class CrashDetectorLiveTests: XCTestCase {
    private func waitUntil(_ t: TimeInterval, _ c: () -> Bool) async -> Bool {
        let s = Date(); while Date().timeIntervalSince(s) < t { if c() { return true }; try? await Task.sleep(for: .milliseconds(200)) }
        return c()
    }

    func testCounterDetectsInjectedCrash() async throws {
        let adb = try XCTUnwrap(AndroidToolchain.adbURL(), "adb not found")
        let model = AppModel(); model.startDiscovery()
        let ready = await waitUntil(10) { model.devices.contains { $0.platform == .android && $0.state.isReady } }
        try XCTSkipUnless(ready, "no Android device")
        let device = model.devices.first { $0.platform == .android && $0.state.isReady }!

        let session = try XCTUnwrap(model.startSession(for: device))
        _ = await waitUntil(8) { session.totalCount > 0 }
        let before = session.crashCount

        _ = try? await CommandRunner.run(adb, ["-s", device.id, "shell", "log", "-p", "e", "-t", "AndroidRuntime", "FATAL EXCEPTION: main"])

        let detected = await waitUntil(8) { session.crashCount > before }
        XCTAssertTrue(detected, "injected crash not counted")
        XCTAssertNotNil(session.lastCrashSeq)
        XCTAssertTrue(session.visible.contains { $0.isMarker && $0.markerCritical }, "expected a red crash marker")
        model.closeSession(session.id)
    }
}
