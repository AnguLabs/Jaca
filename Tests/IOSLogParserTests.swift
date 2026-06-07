import XCTest
@testable import Squeeze

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
        let raw = "Jun  7 07:24:04 iPhone SpringBoard(UIKit)[123] <Notice>: hello world"
        let line = IOSSyslogParser.parse(raw, year: 2026)
        XCTAssertNotNil(line)
        XCTAssertEqual(line?.level, .info)
        XCTAssertEqual(line?.pid, 123)
        XCTAssertEqual(line?.processName, "SpringBoard(UIKit)")
        XCTAssertEqual(line?.message, "hello world")
    }

    func testLevelMapping() {
        XCTAssertEqual(IOSSyslogParser.mapLevel("Warning"), .warn)
        XCTAssertEqual(IOSSyslogParser.mapLevel("Error"), .error)
        XCTAssertEqual(IOSSyslogParser.mapLevel("Fault"), .fatal)
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
}
