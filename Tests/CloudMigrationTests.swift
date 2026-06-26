import XCTest
@testable import Jaca

/// Guards the cache against data loss when a new release adds a field: every persisted model must
/// decode old JSON (missing the new key) by falling back to defaults, never failing the load.
final class CloudMigrationTests: XCTestCase {

    /// The actual regression: a projects.json written before `favoriteLabelKeysByLogName` existed
    /// must still load (previously the synthesized decoder threw on the missing key → empty list).
    func testCloudProjectDecodesOldSchemaWithoutFavorites() {
        let json = """
        [{"projectID":"p","displayName":"Prod","selectedLogName":"projects/p/logs/x",
          "logNames":["projects/p/logs/x"],
          "labelKeysByLogName":{"projects/p/logs/x":["env","user_id"]}}]
        """
        let projects = CloudPersistence.decodeArray(CloudProject.self, from: Data(json.utf8))
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].projectID, "p")
        XCTAssertEqual(projects[0].displayName, "Prod")
        XCTAssertEqual(projects[0].labelKeysByLogName["projects/p/logs/x"], ["env", "user_id"])
        XCTAssertTrue(projects[0].favoriteLabelKeysByLogName.isEmpty)   // defaulted, not a failure
    }

    func testCloudProjectMinimalOnlyRequiresProjectID() {
        let projects = CloudPersistence.decodeArray(CloudProject.self, from: Data(#"[{"projectID":"p"}]"#.utf8))
        XCTAssertEqual(projects.first?.projectID, "p")
        XCTAssertEqual(projects.first?.logNames, [])
    }

    func testCloudProjectIgnoresUnknownFutureKeys() {
        let projects = CloudPersistence.decodeArray(CloudProject.self, from: Data(#"[{"projectID":"p","somethingNew":42}]"#.utf8))
        XCTAssertEqual(projects.first?.projectID, "p")
    }

    func testDecodeArraySkipsCorruptRecords() {
        // The middle record has no projectID and is skipped; the rest survive.
        let json = #"[{"projectID":"good"},{"displayName":"no id"},{"projectID":"good2"}]"#
        let projects = CloudPersistence.decodeArray(CloudProject.self, from: Data(json.utf8))
        XCTAssertEqual(projects.map(\.projectID), ["good", "good2"])
    }

    func testCloudProjectRoundTripWithFavorites() throws {
        var project = CloudProject(projectID: "p")
        project.favoriteLabelKeysByLogName = ["": ["user_id"]]
        let data = try JSONEncoder().encode([project])
        let back = CloudPersistence.decodeArray(CloudProject.self, from: data)
        XCTAssertEqual(back.first?.favoriteLabelKeysByLogName[""], ["user_id"])
    }

    /// Open-tabs state: a malformed record is skipped, the rest (incl. a cloud tab) survive —
    /// so one bad tab can't wipe the whole strip.
    func testTabDescriptorsDecodeCloudTabAndSkipBadRecords() {
        let json = """
        [{"kind":"cloud","projectID":"p","displayName":"Prod","platform":"android","deviceID":"",
          "minLevel":0,"query":"","isRegex":false,"packageLabel":"",
          "cloudTimeRange":{"last":{"minutes":360}},
          "cloudQuery":{"textConditions":[],"textCombineOr":true,"severitySet":[],
                        "labelConditions":[],"labelCombineOr":false}},
         {"displayName":"no kind — corrupt"},
         {"kind":"log","platform":"iosSimulator","deviceID":"X","displayName":"iPhone",
          "minLevel":0,"query":"","isRegex":false,"packageLabel":""}]
        """
        let tabs = CloudPersistence.decodeArray(TabDescriptor.self, from: Data(json.utf8))
        XCTAssertEqual(tabs.count, 2)                       // the kind-less record is skipped
        XCTAssertEqual(tabs[0].kind, .cloud)
        XCTAssertEqual(tabs[0].projectID, "p")
        XCTAssertEqual(tabs[0].cloudTimeRange, .last(minutes: 360))
        XCTAssertEqual(tabs[1].kind, .log)
    }

    func testTabDescriptorOldSchemaMinimalFields() {
        let tabs = CloudPersistence.decodeArray(
            TabDescriptor.self, from: Data(#"[{"kind":"log","platform":"android","deviceID":"abc"}]"#.utf8))
        XCTAssertEqual(tabs.first?.deviceID, "abc")
        XCTAssertEqual(tabs.first?.displayName, "")          // defaulted, not a decode failure
    }

    /// Embedded query models (persisted in templates.json and the open-tabs state) tolerate
    /// missing keys too.
    func testCloudLogQueryDecodesOldSchema() throws {
        let json = #"{"textConditions":[{"value":"boom"}]}"#   // no mode, no combine flags
        let query = try JSONDecoder().decode(CloudLogQuery.self, from: Data(json.utf8))
        XCTAssertEqual(query.textConditions.count, 1)
        XCTAssertEqual(query.textConditions[0].value, "boom")
        XCTAssertEqual(query.textConditions[0].mode, .contains)   // defaulted
        XCTAssertTrue(query.textCombineOr)                        // defaulted
    }
}
