import XCTest
@testable import Squeeze

final class HARExportTests: XCTestCase {
    func testProducesValidHAR() throws {
        var txn = NetworkTransaction(method: "GET", url: "https://api.example.com/v1/users?page=2",
                                     host: "api.example.com", scheme: "https",
                                     requestHeaders: [HeaderPair(name: "Accept", value: "application/json")])
        txn.statusCode = 200
        txn.responseHeaders = [HeaderPair(name: "Content-Type", value: "application/json")]
        txn.responseBody = Data(#"{"ok":true}"#.utf8)
        txn.responseBytes = 11
        txn.responseContentType = "application/json"
        txn.responseReceivedAt = txn.startedAt.addingTimeInterval(0.1)
        txn.finishedAt = txn.startedAt.addingTimeInterval(0.25)

        let data = try XCTUnwrap(HARExport.data(from: [txn]))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let log = try XCTUnwrap(root["log"] as? [String: Any])
        XCTAssertEqual(log["version"] as? String, "1.2")
        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        let request = try XCTUnwrap(entries[0]["request"] as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "GET")
        let query = try XCTUnwrap(request["queryString"] as? [[String: String]])
        XCTAssertEqual(query.first?["name"], "page")
        let response = try XCTUnwrap(entries[0]["response"] as? [String: Any])
        XCTAssertEqual(response["status"] as? Int, 200)
    }
}

final class TabDescriptorTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let d = TabDescriptor(kind: .log, platform: .android, deviceID: "emulator-5554",
                              displayName: "My Tab", minLevel: LogLevel.warn.rawValue,
                              query: "error", isRegex: true, packageLabel: "com.foo")
        let data = try JSONEncoder().encode([d])
        let back = try JSONDecoder().decode([TabDescriptor].self, from: data)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].kind, .log)
        XCTAssertEqual(back[0].platform, .android)
        XCTAssertEqual(back[0].displayName, "My Tab")
        XCTAssertEqual(back[0].packageLabel, "com.foo")
        XCTAssertTrue(back[0].matches(d))
    }
}
