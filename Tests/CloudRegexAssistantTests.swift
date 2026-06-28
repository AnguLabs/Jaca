import XCTest
@testable import Jaca

/// The regex Ask-Claude use case: the system prompt carries the RE2 constraints + JSON contract +
/// the field context, and replies parse (tolerating fences).
final class CloudRegexAssistantTests: XCTestCase {

    func test_systemPrompt_carriesRE2ContractAndField() {
        let prompt = CloudRegexAssistant.systemPrompt(field: "labels.platform")
        XCTAssertTrue(prompt.contains("\"regex\""))          // JSON contract
        XCTAssertTrue(prompt.contains("RE2"))                // the engine
        XCTAssertTrue(prompt.contains("backreferences"))     // the key limitation
        XCTAssertTrue(prompt.contains("labels.platform"))    // field context
    }

    func test_parse_fencedReply() {
        let text = """
        ```json
        {"regex": "^202606(2[89]|[3-9][0-9])[0-9]$", "explanation": "starts 202606, XX>27, any digit"}
        ```
        """
        let suggestion = CloudRegexAssistant.parse(text)
        XCTAssertEqual(suggestion?.regex, "^202606(2[89]|[3-9][0-9])[0-9]$")
        XCTAssertEqual(suggestion?.explanation, "starts 202606, XX>27, any digit")
    }

    func test_parse_nonJSONReturnsNil() {
        XCTAssertNil(CloudRegexAssistant.parse("sorry, I can't"))
    }
}
