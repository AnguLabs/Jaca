import XCTest
@testable import Jaca

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
        setenv("JACA_UITEST", "1", 1)   // isolate from restored tabs / persistence
        defer { unsetenv("JACA_UITEST") }
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

        // Level filter narrows the visible set (applied off-main, so poll for it).
        session.setMinLevel(.error)
        let levelApplied = await waitUntil(timeout: 3) { session.visible.allSatisfy { $0.level >= .error } }
        XCTAssertTrue(levelApplied, "min-level filter not applied")

        // Reset + text filter (no crash; matches are a subset → here, empty).
        session.setMinLevel(.verbose)
        session.setQuery("zzz_nomatch_zzz")
        let queryApplied = await waitUntil(timeout: 3) {
            session.visible.allSatisfy { $0.message.contains("zzz_nomatch_zzz") || $0.tag.contains("zzz_nomatch_zzz") }
        }
        XCTAssertTrue(queryApplied)

        // Clear empties the view.
        session.clear()
        XCTAssertEqual(session.visible.count, 0)

        model.closeSession(session.id)
        XCTAssertTrue(model.sessions.isEmpty)

        // History recorded the session.
        let sessions = await model.history?.sessions(deviceID: device.id) ?? []
        XCTAssertTrue(sessions.contains { $0.id == session.id.uuidString }, "session not persisted to history")
    }

    /// Installed-apps enumeration (the filter dropdown's data) for whatever
    /// devices are connected.
    func testInstalledAppsLive() async throws {
        setenv("JACA_UITEST", "1", 1)
        defer { unsetenv("JACA_UITEST") }
        let model = AppModel()
        model.startDiscovery()
        _ = await waitUntil(timeout: 10) { !model.devices.isEmpty }

        if let android = model.devices.first(where: { $0.platform == .android && $0.state.isReady }) {
            let apps = await InstalledApps.list(for: android, adbURL: AndroidToolchain.adbURL())
            XCTAssertFalse(apps.isEmpty, "no Android packages enumerated")
            XCTAssertTrue(apps.contains { $0.id.contains(".") }, "expected package-like ids")
        }
        if let sim = model.devices.first(where: { $0.platform == .iosSimulator && $0.state.isReady }) {
            let apps = await InstalledApps.list(for: sim, adbURL: nil)
            XCTAssertFalse(apps.isEmpty, "no simulator apps enumerated")
            XCTAssertTrue(apps.contains { $0.id == "com.apple.mobilesafari" }, "Safari not listed")
            XCTAssertTrue(apps.contains { $0.name != nil }, "expected human names on iOS")
        }
    }

    /// iOS Simulator: stream general logs, then filter to a specific app
    /// (MobileSafari) and confirm only that app's lines remain.
    func testSimulatorGeneralAndAppSpecificLogsLive() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(AppleToolchain.hasFullXcode, "no full Xcode")
        setenv("JACA_UITEST", "1", 1)
        defer { unsetenv("JACA_UITEST") }

        let model = AppModel()
        model.startDiscovery()
        let gotSim = await waitUntil(timeout: 12) {
            model.devices.contains { $0.platform == .iosSimulator && $0.state.isReady }
        }
        try XCTSkipUnless(gotSim, "no booted simulator")
        let sim = model.devices.first { $0.platform == .iosSimulator && $0.state.isReady }!

        // Generate app-specific traffic.
        let bundleID = "com.apple.mobilesafari"
        _ = try? await CommandRunner.run(AppleToolchain.xcrun, ["simctl", "launch", sim.id, bundleID],
                                         environment: AppleToolchain.environment())
        _ = try? await CommandRunner.run(AppleToolchain.xcrun, ["simctl", "openurl", sim.id, "https://example.com"],
                                         environment: AppleToolchain.environment())

        // 1) General simulator logs stream.
        let session = try XCTUnwrap(model.startSession(for: sim), "startSession returned nil")
        let streamed = await waitUntil(timeout: 15) { session.totalCount > 0 }
        XCTAssertTrue(streamed, "no simulator logs streamed")
        let processesUnfiltered = Set(session.visible.compactMap { $0.processName })
        XCTAssertGreaterThanOrEqual(processesUnfiltered.count, 1, "expected at least one process")

        // 2) Filter to the specific app and keep it busy.
        session.setPackage("MobileSafari")
        _ = try? await CommandRunner.run(AppleToolchain.xcrun, ["simctl", "openurl", sim.id, "https://apple.com"],
                                         environment: AppleToolchain.environment())
        let appLines = await waitUntil(timeout: 12) { session.visible.count >= 3 }
        XCTAssertTrue(appLines, "no MobileSafari-specific lines captured")
        XCTAssertTrue(session.visible.allSatisfy {
            ($0.processName ?? "").localizedCaseInsensitiveContains("MobileSafari")
                || $0.tag.localizedCaseInsensitiveContains("MobileSafari")
        }, "app filter leaked unrelated processes")
        XCTAssertEqual(session.filter.packageLabel, "MobileSafari")

        model.closeSession(session.id)
    }

    /// Reproduces the exact "select an iOS app in the dropdown" path: list apps,
    /// then apply one as the package filter (what the picker row click does).
    func testSelectIOSAppFilterFromDropdownLive() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(AppleToolchain.hasFullXcode, "no full Xcode")
        setenv("JACA_UITEST", "1", 1)
        defer { unsetenv("JACA_UITEST") }

        let model = AppModel()
        model.startDiscovery()
        let gotSim = await waitUntil(timeout: 12) {
            model.devices.contains { $0.platform == .iosSimulator && $0.state.isReady }
        }
        try XCTSkipUnless(gotSim, "no booted simulator")
        let sim = model.devices.first { $0.platform == .iosSimulator && $0.state.isReady }!

        let session = try XCTUnwrap(model.startSession(for: sim))
        _ = await waitUntil(timeout: 12) { session.totalCount > 0 }

        let apps = await session.installedApps()
        XCTAssertFalse(apps.isEmpty)
        let app = apps.first { $0.id == "com.apple.mobilesafari" } ?? apps[0]

        // The dropdown row click does exactly this:
        session.setPackage(app.id)
        XCTAssertEqual(session.filter.packageLabel, app.id)
        XCTAssertEqual(session.filter.processNameQuery, app.id)

        // Selecting "All processes" clears it.
        session.setPackage("")
        XCTAssertEqual(session.filter.processNameQuery, "")

        model.closeSession(session.id)
    }

}
