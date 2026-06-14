import XCTest

/// Drives the real app to validate flows and catch crashes/hangs. Every step has
/// a timeout; if the app dies, `assertAlive` fails fast at the offending step.
final class SmokeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["JACA_UITEST"] = "1"
        app.launch()
        // Bring it frontmost — guards against "Running Background" activation flakiness.
        if app.state != .runningForeground { app.activate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "window never appeared")
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private func assertAlive(_ context: String, line: UInt = #line) {
        XCTAssertEqual(app.state, .runningForeground, "app not running after \(context)", line: line)
    }

    /// First *enabled* (ready) device row, or nil if none within `timeout`.
    private func firstReadyDeviceRow(timeout: TimeInterval = 8) -> XCUIElement? {
        let rows = app.buttons.matching(identifier: "deviceRow")
        guard rows.firstMatch.waitForExistence(timeout: timeout) else { return nil }
        for i in 0..<rows.count {
            let row = rows.element(boundBy: i)
            if row.isEnabled { return row }
        }
        return nil
    }

    /// Clicks a control reliably even when the app window starts inactive: the
    /// first click on an inactive macOS window only activates it, so we activate
    /// first and re-click if the expected result hasn't appeared.
    @discardableResult
    private func robustClickDevice(_ row: XCUIElement, expect: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        app.activate()
        row.click()
        if expect.waitForExistence(timeout: 3) { return true }
        row.click()                       // window was just activated by the first click
        return expect.waitForExistence(timeout: timeout)
    }

    /// Forces the app window to become key/active. macOS doesn't reliably make a
    /// test-launched window frontmost, but presenting a sheet does — so we open and
    /// close Settings, after which content clicks fire normally.
    private func ensureWindowActive() {
        app.activate()
        let settings = app.buttons["settingsButton"]
        guard settings.waitForExistence(timeout: 6) else { return }
        settings.click()
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 4) { done.click() }
    }

    /// First enabled device row whose label contains `text` (e.g. "iPhone").
    private func deviceRow(matching text: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let rows = app.buttons.matching(identifier: "deviceRow")
        guard rows.firstMatch.waitForExistence(timeout: timeout) else { return nil }
        for i in 0..<rows.count {
            let row = rows.element(boundBy: i)
            if row.isEnabled && row.label.contains(text) { return row }
        }
        return nil
    }

    // MARK: - Tests

    func testLaunchesAndShowsShell() throws {
        XCTAssertTrue(app.staticTexts["Devices"].waitForExistence(timeout: 8), "sidebar header missing")
        assertAlive("launch")
    }

    func testSettingsSheetOpensAndCloses() throws {
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.click()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 6), "Settings sheet didn't open")
        assertAlive("open settings")
        done.click()
        assertAlive("close settings")
    }

    func testHistorySheetOpensAndCloses() throws {
        let history = app.buttons["historyButton"]
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        history.click()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 6), "History sheet didn't open")
        assertAlive("open history")
        done.click()
        assertAlive("close history")
    }

    func testStartLogcatSession() throws {
        let row = try XCTUnwrap(firstReadyDeviceRow(), "no ready device connected")
        let logcatOption = app.buttons["Start Logcat"]
        XCTAssertTrue(robustClickDevice(row, expect: logcatOption, timeout: 10),
                      "inspect menu didn't open")
        logcatOption.click()
        XCTAssertTrue(app.buttons["logTransportButton"].waitForExistence(timeout: 10),
                      "log session didn't open")
        // Let it stream — this is where a render/observation crash would surface.
        Thread.sleep(forTimeInterval: 3)
        assertAlive("start logcat + stream")
    }

    func testMultipleLogcatTabs() throws {
        let row = try XCTUnwrap(firstReadyDeviceRow(), "no ready device connected")
        let logcatOption = app.buttons["Start Logcat"]
        XCTAssertTrue(robustClickDevice(row, expect: logcatOption, timeout: 10),
                      "inspect menu didn't open")
        logcatOption.click()
        XCTAssertTrue(app.buttons["logTransportButton"].waitForExistence(timeout: 10),
                      "first tab didn't open")
        assertAlive("first tab")
        // Re-open the menu and start a second, independent logcat tab.
        XCTAssertTrue(robustClickDevice(row, expect: logcatOption, timeout: 8),
                      "inspect menu didn't reopen")
        logcatOption.click()
        Thread.sleep(forTimeInterval: 2)
        // Two tabs should now exist (each tab has a close button).
        XCTAssertGreaterThanOrEqual(app.buttons.matching(identifier: "tabClose").count, 2)
        assertAlive("second tab")
    }

    /// Auto-opens a logcat session (no device-row click) and lets it stream into the
    /// NSTableView-backed log list — a render/observation crash would surface here.
    func testAutoLogcatStreamsIntoTable() throws {
        launchWithAutoSession("android")
        guard app.buttons["logTransportButton"].waitForExistence(timeout: 15) else {
            throw XCTSkip("no ready Android device to auto-open a log session")
        }
        Thread.sleep(forTimeInterval: 4)   // stream a few seconds of real logcat
        assertAlive("auto logcat streaming into the virtualized table")
    }

    /// Launch with a session auto-opened for `platform` (bypasses the device-row
    /// click, which macOS won't deliver to an inactive test window).
    private func launchWithAutoSession(_ platform: String) {
        app = XCUIApplication()
        app.launchEnvironment["JACA_UITEST"] = "1"
        app.launchEnvironment["JACA_AUTO_SESSION"] = platform
        app.launch()
        _ = app.windows.firstMatch.waitForExistence(timeout: 15)
        ensureWindowActive()
    }

    /// Reproduces the reported crash: open the app/package picker on an iOS-sim
    /// session and click an app row.
    func testIOSAppFilterPickerDoesNotCrash() throws {
        launchWithAutoSession("iosSimulator")
        try XCTSkipUnless(app.buttons["logTransportButton"].waitForExistence(timeout: 15),
                          "no iOS sim session (no booted sim?)")

        let picker = app.buttons["packagePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "package picker not found")
        picker.click()
        let appRows = app.buttons.matching(identifier: "appRow")
        XCTAssertTrue(appRows.firstMatch.waitForExistence(timeout: 12), "app list didn't load")
        let target = appRows.count > 1 ? appRows.element(boundBy: 1) : appRows.firstMatch
        target.click()                               // <-- the reported crash point
        Thread.sleep(forTimeInterval: 2)
        assertAlive("select iOS app in picker")
    }

    func testStartNetworkInspection() throws {
        let row = try XCTUnwrap(firstReadyDeviceRow(), "no ready device connected")
        let networkOption = app.buttons["Inspect Network"]
        XCTAssertTrue(robustClickDevice(row, expect: networkOption, timeout: 10),
                      "inspect menu didn't open")
        networkOption.click()
        let transport = app.buttons["netTransportButton"]
        XCTAssertTrue(transport.waitForExistence(timeout: 10), "network session didn't open")
        Thread.sleep(forTimeInterval: 2)
        assertAlive("start network inspection")
    }
}
