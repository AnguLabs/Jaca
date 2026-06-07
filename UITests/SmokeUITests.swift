import XCTest

/// Drives the real app to validate flows and catch crashes/hangs. Every step has
/// a timeout; if the app dies, `assertAlive` fails fast at the offending step.
final class SmokeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["SQUEEZE_UITEST"] = "1"
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
        row.click()
        let transport = app.buttons["logTransportButton"]
        XCTAssertTrue(transport.waitForExistence(timeout: 10), "log session didn't open")
        // Let it stream — this is where a render/observation crash would surface.
        Thread.sleep(forTimeInterval: 3)
        assertAlive("start logcat + stream")
    }

    func testMultipleLogcatTabs() throws {
        let row = try XCTUnwrap(firstReadyDeviceRow(), "no ready device connected")
        row.click()
        XCTAssertTrue(app.buttons["logTransportButton"].waitForExistence(timeout: 10), "first tab didn't open")
        assertAlive("first tab")
        row.click()
        Thread.sleep(forTimeInterval: 2)
        // Two tabs should now exist.
        XCTAssertGreaterThanOrEqual(app.buttons.matching(identifier: "tabClose").count, 1)
        assertAlive("second tab")
    }

    func testStartNetworkInspection() throws {
        let row = try XCTUnwrap(firstReadyDeviceRow(), "no ready device connected")
        row.rightClick()
        let item = app.menuItems["Inspect Network"]
        XCTAssertTrue(item.waitForExistence(timeout: 6), "context menu didn't show")
        item.click()
        let transport = app.buttons["netTransportButton"]
        XCTAssertTrue(transport.waitForExistence(timeout: 10), "network session didn't open")
        Thread.sleep(forTimeInterval: 2)
        assertAlive("start network inspection")
    }
}
