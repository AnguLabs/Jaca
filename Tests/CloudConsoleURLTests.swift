import XCTest
@testable import Jaca

final class CloudConsoleURLTests: XCTestCase {

    func testBuildContainsProjectAndEncodedQuery() {
        let url = CloudConsoleURL.build(project: "my-proj", filter: #"textPayload:"foo" AND severity>=ERROR"#)
        XCTAssertTrue(url.hasPrefix("https://console.cloud.google.com/logs/query;query="))
        XCTAssertTrue(url.contains("?project=my-proj"))
        XCTAssertFalse(url.contains("\""))   // quotes are percent-encoded
        XCTAssertFalse(url.contains(" "))     // spaces are percent-encoded
    }

    func testBuildEmptyFilterIsProjectLink() {
        XCTAssertEqual(CloudConsoleURL.build(project: "p", filter: ""),
                       "https://console.cloud.google.com/logs/query?project=p")
    }

    func testRoundTrip() {
        let filter = #"logName="projects/p/logs/stdout" AND textPayload:"boom" AND severity>=ERROR"#
        let url = CloudConsoleURL.build(project: "p", filter: filter)
        let parsed = CloudConsoleURL.parse(url)
        XCTAssertEqual(parsed.project, "p")
        XCTAssertEqual(parsed.query, filter)
    }

    func testParseRealisticURL() {
        let url = "https://console.cloud.google.com/logs/query;query=severity%3E%3DERROR;timeRange=PT1H?project=demo-prod-42&hl=en"
        let parsed = CloudConsoleURL.parse(url)
        XCTAssertEqual(parsed.project, "demo-prod-42")
        XCTAssertEqual(parsed.query, "severity>=ERROR")
    }

    func testParseNoQuery() {
        let parsed = CloudConsoleURL.parse("https://console.cloud.google.com/logs/query?project=p")
        XCTAssertEqual(parsed.project, "p")
        XCTAssertNil(parsed.query)
    }

    func testLooksLikeConsoleURL() {
        XCTAssertTrue(CloudConsoleURL.looksLikeConsoleURL("https://console.cloud.google.com/logs/query;query=x"))
        XCTAssertFalse(CloudConsoleURL.looksLikeConsoleURL("https://example.com"))
    }
}
