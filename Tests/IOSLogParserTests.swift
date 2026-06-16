import XCTest
@testable import Jaca

final class SimulatorLogParserTests: XCTestCase {
    func testParsesNdjsonLine() {
        let raw = #"{"messageType":"Error","subsystem":"com.myapp","category":"net","processID":4242,"threadID":99,"eventMessage":"request failed","processImagePath":"/path/MyApp.app/MyApp","timestamp":"2026-06-07 07:24:04.372181-0300"}"#
        let line = SimulatorLogParser.parse(raw)
        XCTAssertNotNil(line)
        XCTAssertEqual(line?.level, .error)
        XCTAssertEqual(line?.tag, "com.myapp")
        XCTAssertEqual(line?.pid, 4242)
        XCTAssertEqual(line?.message, "request failed")
        XCTAssertEqual(line?.processName, "MyApp")
    }

    func testLevelMapping() {
        XCTAssertEqual(SimulatorLogParser.mapLevel("Debug"), .debug)
        XCTAssertEqual(SimulatorLogParser.mapLevel("Info"), .info)
        XCTAssertEqual(SimulatorLogParser.mapLevel("Default"), .info)
        XCTAssertEqual(SimulatorLogParser.mapLevel("Fault"), .fatal)
    }

    func testIgnoresNonObjectLines() {
        XCTAssertNil(SimulatorLogParser.parse("["))
        XCTAssertNil(SimulatorLogParser.parse("]"))
        XCTAssertNil(SimulatorLogParser.parse(""))
    }

    func testParsesBootedSimulators() {
        let json = #"""
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[
          {"udid":"AAA","name":"iPhone 17","state":"Booted"},
          {"udid":"BBB","name":"iPhone Air","state":"Shutdown"}
        ]}}
        """#
        let devices = SimulatorDeviceParser.parseBooted(Data(json.utf8))
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, "AAA")
        XCTAssertEqual(devices.first?.state, .booted)
        XCTAssertEqual(devices.first?.platform, .iosSimulator)
    }
}

final class IOSSyslogParserTests: XCTestCase {
    func testParsesSyslogLine() {
        let raw = "Jun  7 07:24:04 SpringBoard(UIKit)[123] <Notice>: hello world"
        let line = IOSSyslogParser.parse(raw, year: 2026)
        XCTAssertNotNil(line)
        XCTAssertEqual(line?.level, .info)
        XCTAssertEqual(line?.pid, 123)
        XCTAssertEqual(line?.processName, "SpringBoard(UIKit)")
        XCTAssertEqual(line?.message, "hello world")
    }

    /// Real libimobiledevice output: sub-second timestamp, no hostname, and a
    /// process name containing a space — must parse so the app filter can match it.
    func testParsesSubSecondAndSpacedProcessName() {
        let raw = "Jun 15 16:15:24.604380 Teya Dev(Security)[5812] <Notice>: SecTaskLoadEntitlements failed"
        let line = IOSSyslogParser.parse(raw, year: 2026)
        XCTAssertNotNil(line)
        XCTAssertEqual(line?.pid, 5812)
        XCTAssertEqual(line?.level, .info)
        XCTAssertEqual(line?.processName, "Teya Dev(Security)")
        XCTAssertEqual(line?.message, "SecTaskLoadEntitlements failed")
        XCTAssertTrue(line?.processName?.contains("Teya Dev") == true)
    }

    func testLevelMapping() {
        XCTAssertEqual(IOSSyslogParser.mapLevel("Warning"), .warn)
        XCTAssertEqual(IOSSyslogParser.mapLevel("Error"), .error)
        XCTAssertEqual(IOSSyslogParser.mapLevel("Fault"), .fatal)
    }
}

final class IOSDeviceConsoleParserTests: XCTestCase {
    /// An os_log line mirrored to stderr by OS_ACTIVITY_DT_MODE, with a subsystem.
    func testParsesOsLogMirrorWithSubsystem() {
        let raw = "2026-06-15 16:56:41.265796-0300 Teya Dev[5904:1882516] [Firebase/Crashlytics] Version 11.15.0"
        let line = IOSDeviceConsoleParser.parse(raw)
        XCTAssertEqual(line?.processName, "Teya Dev")
        XCTAssertEqual(line?.pid, 5904)
        XCTAssertEqual(line?.tag, "Firebase/Crashlytics")
        XCTAssertEqual(line?.message, "Version 11.15.0")
        XCTAssertEqual(line?.isConsoleOutput, false)
    }

    /// The app's own Logger emits `🟢 (Category) message` under an empty `[]`
    /// subsystem. The console mirror carries no level, so recover it from the glyph
    /// and lift the category into the tag.
    func testParsesAppLoggerGlyphAndCategory() {
        let raw = "2026-06-15 16:56:41.676994-0300 Teya Dev[5904:1882561] [] 🟢 (StoreService) loadStores companyId=96346056"
        let line = IOSDeviceConsoleParser.parse(raw)
        XCTAssertEqual(line?.level, .info)                              // 🟢 → info
        XCTAssertEqual(line?.tag, "StoreService")                      // (Category) → tag
        XCTAssertEqual(line?.message, "loadStores companyId=96346056") // glyph + category stripped
        XCTAssertFalse(line?.message.contains("<private>") == true)    // un-redacted
    }

    /// 🟡 → warn, 🔴 → error, each lifting its category.
    func testGlyphLevelsWarnAndError() {
        let warn = IOSDeviceConsoleParser.parse(
            "2026-06-15 16:56:43.751416-0300 Teya Dev[5904:1882522] [] 🟡 (IdDeviceError) IDP code=403")
        XCTAssertEqual(warn?.level, .warn)
        XCTAssertEqual(warn?.tag, "IdDeviceError")
        XCTAssertEqual(warn?.message, "IDP code=403")

        let err = IOSDeviceConsoleParser.parse(
            "2026-06-15 16:56:43.758253-0300 Teya Dev[5904:1882522] [] 🔴 (safeSuspendRunCatching) Error")
        XCTAssertEqual(err?.level, .error)
        XCTAssertEqual(err?.tag, "safeSuspendRunCatching")
    }

    /// Plain stdout (print/println) — never in the unified log — is kept as console output.
    func testParsesRawStdout() {
        let line = IOSDeviceConsoleParser.parse("Sardine SDK initialized successfully")
        XCTAssertEqual(line?.isConsoleOutput, true)
        XCTAssertEqual(line?.tag, "stdout")
        XCTAssertEqual(line?.message, "Sardine SDK initialized successfully")
    }

    /// devicectl's own chrome and blank lines are dropped.
    func testDropsDevicectlChromeAndBlanks() {
        XCTAssertNil(IOSDeviceConsoleParser.parse("16:56:40  Acquired tunnel connection to device."))
        XCTAssertNil(IOSDeviceConsoleParser.parse("Launched application with com.teya.ac.dev bundle identifier."))
        XCTAssertNil(IOSDeviceConsoleParser.parse("Waiting for the application to terminate…"))
        XCTAssertNil(IOSDeviceConsoleParser.parse("   "))
    }
}

final class IOSDeviceParserTests: XCTestCase {
    func testParsesDevicectlOutput() {
        let json = #"""
        {"result":{"devices":[
          {"hardwareProperties":{"udid":"UDID-1","marketingName":"iPhone 15"},
           "deviceProperties":{"name":"My iPhone"},
           "connectionProperties":{"tunnelState":"connected"}}
        ]}}
        """#
        let devices = IOSDeviceParser.parse(Data(json.utf8))
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, "UDID-1")
        XCTAssertEqual(devices.first?.model, "My iPhone")
        XCTAssertEqual(devices.first?.state, .connected)
        XCTAssertEqual(devices.first?.platform, .iosDevice)
    }

    /// A wired, paired iPhone sits at tunnelState "disconnected" until something
    /// talks to it — devicectl brings the tunnel up lazily. It's still usable
    /// (idevicesyslog goes through usbmuxd), so it must read as connected.
    func testPairedDeviceWithLazyTunnelIsConnected() {
        let json = #"""
        {"result":{"devices":[
          {"hardwareProperties":{"udid":"00008101-ABC","marketingName":"iPhone 12"},
           "deviceProperties":{"name":"My iPhone"},
           "connectionProperties":{"transportType":"wired","pairingState":"paired","tunnelState":"disconnected"}}
        ]}}
        """#
        let devices = IOSDeviceParser.parse(Data(json.utf8))
        XCTAssertEqual(devices.first?.id, "00008101-ABC")
        XCTAssertEqual(devices.first?.state, .connected)
    }

    /// A remembered-but-absent device reports tunnelState "unavailable" — offline.
    func testUnavailableDeviceIsOffline() {
        let json = #"""
        {"result":{"devices":[
          {"hardwareProperties":{"udid":"UDID-2","marketingName":"iPhone 15"},
           "connectionProperties":{"pairingState":"paired","tunnelState":"unavailable"}}
        ]}}
        """#
        let devices = IOSDeviceParser.parse(Data(json.utf8))
        XCTAssertEqual(devices.first?.state, .offline)
    }

    /// An untrusted (unpaired) device can't be used — offline.
    func testUnpairedDeviceIsOffline() {
        let json = #"""
        {"result":{"devices":[
          {"hardwareProperties":{"udid":"UDID-3","marketingName":"iPhone 15"},
           "connectionProperties":{"pairingState":"unpaired","tunnelState":"connected"}}
        ]}}
        """#
        let devices = IOSDeviceParser.parse(Data(json.utf8))
        XCTAssertEqual(devices.first?.state, .offline)
    }
}
