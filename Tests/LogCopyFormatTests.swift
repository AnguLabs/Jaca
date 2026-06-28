import XCTest
@testable import Jaca

/// The configurable log copy format: token substitution (incl. empty-token space collapse), date
/// formatting, presets, and migration-safe decode.
final class LogCopyFormatTests: XCTestCase {

    // MARK: - substitute

    func test_substitute_basicTokens() {
        let out = LogCopyFormat.substitute("[{level}] {tag}  {message}",
                                           ["level": "E", "tag": "Auth", "message": "boom"])
        XCTAssertEqual(out, "[E] Auth  boom")
    }

    func test_substitute_emptyTokenEatsFollowingSpace() {
        // No tag → the space after {tag} is dropped (not a double space before the message).
        let out = LogCopyFormat.substitute("[{level}] {tag} {message}",
                                           ["level": "E", "tag": "", "message": "boom"])
        XCTAssertEqual(out, "[E] boom")
    }

    func test_substitute_emptyTokenEatsPrecedingSpaceAtTail() {
        let out = LogCopyFormat.substitute("{message} {tag}", ["message": "boom", "tag": ""])
        XCTAssertEqual(out, "boom")
    }

    func test_substitute_leadingEmptyDate() {
        let out = LogCopyFormat.substitute("{date} {message}", ["date": "", "message": "boom"])
        XCTAssertEqual(out, "boom")
    }

    func test_substitute_unknownTokenStaysLiteral() {
        let out = LogCopyFormat.substitute("{foo} {message}", ["message": "boom"])
        XCTAssertEqual(out, "{foo} boom")
    }

    func test_substitute_messageInternalSpacingPreserved() {
        // Multi-line / indented payloads (pretty JSON) must not be space-collapsed.
        let msg = "{\n  \"a\": 1,\n  \"b\":  2\n}"
        let out = LogCopyFormat.substitute("{message}", ["message": msg])
        XCTAssertEqual(out, msg)
    }

    // MARK: - render + date format

    func test_render_dateFormats() {
        XCTAssertEqual(LogCopyFormat(template: "{date}", dateFormat: "HH:mm:ss").render(LogCopyPresets.sample), "14:23:45")
        XCTAssertEqual(LogCopyFormat(template: "{date}", dateFormat: "mm:ss").render(LogCopyPresets.sample), "23:45")
        XCTAssertEqual(LogCopyFormat(template: "{date}  {message}", dateFormat: "mm:ss").render(LogCopyPresets.sample),
                       "23:45  Login failed for user 42")
    }

    func test_render_manyRowsOnePerLine() {
        let fields = [LogCopyPresets.sample, LogCopyPresets.sample]
        let out = LogCopyFormat(template: "{levelShort} {message}", dateFormat: "").render(fields)
        XCTAssertEqual(out, "E Login failed for user 42\nE Login failed for user 42")
    }

    func test_presets_allRenderNonEmptyExamples() {
        for preset in LogCopyPresets.all {
            XCTAssertFalse(preset.format.render(LogCopyPresets.sample).isEmpty, "\(preset.name) rendered empty")
        }
    }

    // MARK: - migration-safe decode

    func test_decode_missingKeysFallBackToDefaults() throws {
        let onlyTemplate = try JSONDecoder().decode(LogCopyFormat.self, from: Data(#"{"template":"{message}"}"#.utf8))
        XCTAssertEqual(onlyTemplate.template, "{message}")
        XCTAssertEqual(onlyTemplate.dateFormat, LogCopyFormat.default.dateFormat)   // defaulted

        let empty = try JSONDecoder().decode(LogCopyFormat.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, .default)
    }
}
