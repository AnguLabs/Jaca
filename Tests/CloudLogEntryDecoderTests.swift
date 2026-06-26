import XCTest
@testable import Jaca

final class CloudLogEntryDecoderTests: XCTestCase {

    private func decode(_ json: String) -> [CloudLogEntry] {
        CloudLogEntryDecoder.decodeArray(Data(json.utf8))
    }

    func testDecodesTextPayloadEntryWithLabelsAndResource() {
        let entries = decode("""
        [
          {
            "insertId": "abc",
            "timestamp": "2024-06-26T10:00:00.123456789Z",
            "receiveTimestamp": "2024-06-26T10:00:00.5Z",
            "severity": "ERROR",
            "logName": "projects/p/logs/run.googleapis.com%2Fstdout",
            "textPayload": "boom",
            "labels": {"env": "prod", "version": "1.2"},
            "resource": {"type": "cloud_run_revision", "labels": {"service_name": "api"}},
            "trace": "projects/p/traces/xyz",
            "spanId": "span1"
          }
        ]
        """)
        XCTAssertEqual(entries.count, 1)
        let e = entries[0]
        XCTAssertEqual(e.insertId, "abc")
        XCTAssertEqual(e.severity, .error)
        XCTAssertEqual(e.message, "boom")
        XCTAssertEqual(e.payloadKind, .text)
        XCTAssertEqual(e.labels["env"], "prod")
        XCTAssertEqual(e.labels["version"], "1.2")
        XCTAssertEqual(e.resourceType, "cloud_run_revision")
        XCTAssertEqual(e.resourceLabels["service_name"], "api")
        XCTAssertEqual(e.logId, "run.googleapis.com/stdout")
        XCTAssertEqual(e.trace, "projects/p/traces/xyz")
        XCTAssertEqual(e.spanId, "span1")
        XCTAssertNotNil(e.receiveTimestamp)
        XCTAssertFalse(e.raw.isEmpty)
    }

    func testJsonPayloadRenderedAndMarkedJson() {
        let entries = decode("""
        [{ "insertId": "x", "timestamp": "2024-06-26T10:00:01Z",
           "jsonPayload": {"message": "hi", "count": 3} }]
        """)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].payloadKind, .json)
        XCTAssertTrue(entries[0].message.contains("count"))
        XCTAssertTrue(entries[0].message.contains("message"))
        XCTAssertTrue(entries[0].labels.isEmpty)
    }

    func testProtoPayloadMarkedProto() {
        let entries = decode("""
        [{ "timestamp": "2024-06-26T10:00:02Z",
           "protoPayload": {"@type": "type.googleapis.com/x", "status": "ok"} }]
        """)
        XCTAssertEqual(entries[0].payloadKind, .proto)
        XCTAssertTrue(entries[0].message.contains("status"))
    }

    func testMissingPayloadIsNone() {
        let entries = decode("""
        [{ "timestamp": "2024-06-26T10:00:03Z" }]
        """)
        XCTAssertEqual(entries[0].payloadKind, .none)
        XCTAssertEqual(entries[0].message, "")
        XCTAssertEqual(entries[0].severity, .default)
    }

    func testHttpRequestSummary() {
        let entries = decode("""
        [{ "timestamp": "2024-06-26T10:00:04Z",
           "httpRequest": {"requestMethod": "GET", "requestUrl": "/v1/foo", "status": 200, "latency": "0.012s"} }]
        """)
        let summary = entries[0].httpRequestSummary ?? ""
        XCTAssertTrue(summary.contains("GET"))
        XCTAssertTrue(summary.contains("/v1/foo"))
        XCTAssertTrue(summary.contains("200"))
    }

    func testEmptyArrayAndGarbage() {
        XCTAssertTrue(decode("[]").isEmpty)
        XCTAssertTrue(decode("not json").isEmpty)
    }
}
