import XCTest
@testable import Squeeze

final class NetworkUtilTests: XCTestCase {
    func testEmulatorUsesLoopbackAlias() {
        let emu = Device(id: "emulator-5554", platform: .android, model: "Emu", state: .connected)
        XCTAssertEqual(ProxyConfigurator.hostAddress(for: emu), "10.0.2.2")
    }

    func testSizeFormatting() {
        XCTAssertEqual(NetworkFormatting.size(0), "—")
        XCTAssertEqual(NetworkFormatting.size(512), "512 B")
        XCTAssertEqual(NetworkFormatting.size(2048), "2.0 KB")
    }

    func testDurationFormatting() {
        XCTAssertEqual(NetworkFormatting.duration(nil), "—")
        XCTAssertEqual(NetworkFormatting.duration(0.25), "250 ms")
        XCTAssertEqual(NetworkFormatting.duration(1.5), "1.50 s")
    }

    func testBodyPrettyPrintsJSON() {
        let data = Data(#"{"b":2,"a":1}"#.utf8)
        let pretty = NetworkFormatting.bodyText(data, contentType: "application/json")
        XCTAssertTrue(pretty.contains("\"a\" : 1"))
        XCTAssertTrue(pretty.contains("\n"))   // multi-line
    }

    func testBodyBinarySummary() {
        let data = Data([0xFF, 0xD8, 0xFF, 0x00, 0x01])
        let text = NetworkFormatting.bodyText(data, contentType: "image/jpeg")
        XCTAssertTrue(text.contains("binary"))
    }

    func testTransactionStatusText() {
        var txn = NetworkTransaction(method: "GET", url: "https://x/y", host: "x", scheme: "https")
        XCTAssertEqual(txn.statusText, "…")
        txn.statusCode = 200
        txn.finishedAt = Date()
        XCTAssertEqual(txn.statusText, "200")
        XCTAssertFalse(txn.isInFlight)
    }
}
