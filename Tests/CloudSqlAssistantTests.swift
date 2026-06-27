import XCTest
@testable import Jaca

/// Pure logic of the Ask-Claude SQL assistant: JSON extraction from model text, bucketing label
/// samples into ≤3 distinct values per key, and the system prompt carrying the right context.
final class CloudSqlAssistantTests: XCTestCase {

    // MARK: - ClaudeJSON.extractObject

    func test_extract_plainObject() {
        let data = ClaudeJSON.extractObject(from: #"{"sql":"SELECT 1","explanation":"x"}"#)
        XCTAssertNotNil(data)
        let s = try? JSONDecoder().decode(CloudSqlAssistant.Suggestion.self, from: data!)
        XCTAssertEqual(s?.sql, "SELECT 1")
    }

    func test_extract_fencedWithProse() {
        let text = """
        Sure! Here is the query:
        ```json
        {"sql": "SELECT insert_id, seq FROM log_entry", "explanation": "all rows"}
        ```
        Hope that helps.
        """
        let data = ClaudeJSON.extractObject(from: text)
        XCTAssertNotNil(data)
        let s = try? JSONDecoder().decode(CloudSqlAssistant.Suggestion.self, from: data!)
        XCTAssertEqual(s?.sql, "SELECT insert_id, seq FROM log_entry")
        XCTAssertEqual(s?.explanation, "all rows")
    }

    func test_extract_bracesInsideStringsDontConfuseIt() {
        let text = #"{"sql":"SELECT json_extract(labels_json,'$.k') FROM t WHERE x = '}'","explanation":"y"}"#
        let data = ClaudeJSON.extractObject(from: text)
        XCTAssertNotNil(data)
        let s = try? JSONDecoder().decode(CloudSqlAssistant.Suggestion.self, from: data!)
        XCTAssertEqual(s?.explanation, "y")
        XCTAssertTrue(s?.sql.contains("'}'") == true)
    }

    func test_extract_noObjectReturnsNil() {
        XCTAssertNil(ClaudeJSON.extractObject(from: "no json here"))
    }

    // MARK: - samples bucketing

    // rows are (scope, key, value, count) ordered count-desc per key, as labelSampleSQL emits.
    private let labelRows: [[String?]] = [
        ["labels", "platform", "ios", "30"],
        ["labels", "platform", "android", "10"],
        ["labels", "platform", "web", "5"],
        ["resource", "service_name", "checkout", "9"],
        ["resource", "service_name", "payments", "4"],
    ]

    func test_samples_defaultsToOneValuePerKey() {
        let samples = CloudSqlAssistant.samples(from: labelRows)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.first { $0.key == "platform" }?.values, ["ios"])         // most common only
        XCTAssertEqual(samples.first { $0.key == "service_name" }?.values, ["checkout"])
    }

    func test_samples_honorsRules_allAndExplicitCount() {
        let rules: [String: LabelExampleRule] = [
            "platform": LabelExampleRule(all: true),       // every value
            "service_name": LabelExampleRule(count: 2),    // two values
        ]
        let samples = CloudSqlAssistant.samples(from: labelRows, rules: rules)
        XCTAssertEqual(samples.first { $0.key == "platform" }?.values, ["ios", "android", "web"])
        XCTAssertEqual(samples.first { $0.key == "service_name" }?.values, ["checkout", "payments"])
    }

    func test_samples_skipsEmptyValues() {
        let rows: [[String?]] = [["labels", "k", nil, "3"], ["labels", "k", "", "2"], ["labels", "k", "v", "1"]]
        let samples = CloudSqlAssistant.samples(from: rows)
        XCTAssertEqual(samples.first?.values, ["v"])
    }

    func test_cardinalities_parsesAndSkipsBadRows() {
        let rows: [[String?]] = [["labels", "platform", "3"], ["resource", "service_name", "2"], ["labels", "bad", nil]]
        let c = CloudSqlAssistant.cardinalities(from: rows)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.first { $0.key == "platform" }?.distinctValues, 3)
    }

    // MARK: - system prompt

    func test_systemPrompt_includesSchemaConventionsAndExactLabelExpressions() {
        let samples = [CloudSqlLabelSample(scope: "labels", key: "platform", values: ["ios", "android"])]
        let prompt = CloudSqlAssistant.systemPrompt(logName: "projects/p/logs/stdout",
                                                    samples: samples, currentSQL: "SELECT 1")
        XCTAssertTrue(prompt.contains("\"sql\""))                       // the JSON contract
        XCTAssertTrue(prompt.contains("insert_id"))                    // schema / mapping rule
        XCTAssertTrue(prompt.contains("severity >= 500"))              // a convention
        // The exact expression must be shown (not "labels.platform"), with the real values.
        XCTAssertTrue(prompt.contains("json_extract(labels_json, '$.platform')"))
        XCTAssertTrue(prompt.contains("ios, android"))
        XCTAssertTrue(prompt.contains("projects/p/logs/stdout"))
        XCTAssertTrue(prompt.contains("SELECT 1"))                     // current query as context
        XCTAssertTrue(prompt.contains("Pretty-print"))                 // formatting instruction
    }
}
