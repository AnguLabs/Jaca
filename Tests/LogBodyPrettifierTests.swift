import XCTest
@testable import Jaca

final class LogBodyPrettifierTests: XCTestCase {
    private func line(_ message: String, tag: String = "Net", level: LogLevel = .info,
                      isMarker: Bool = false) -> LogLine {
        LogLine(seq: 0, timestamp: Date(), level: level, tag: tag, pid: 1, tid: 1,
                message: message, raw: message, isMarker: isMarker)
    }

    // MARK: - JSONReflow

    func testReflowObjectPreservesKeyOrder() {
        let r = JSONReflow.reflow(#"{"b":1,"a":2}"#)
        XCTAssertEqual(r?.pretty, "{\n  \"b\": 1,\n  \"a\": 2\n}")
        XCTAssertEqual(r?.compact, #"{"b":1,"a":2}"#)
    }

    func testReflowNested() {
        let r = JSONReflow.reflow(#"{"a":{"x":[1,2]},"b":[3]}"#)
        XCTAssertEqual(r?.pretty,
            "{\n  \"a\": {\n    \"x\": [\n      1,\n      2\n    ]\n  },\n  \"b\": [\n    3\n  ]\n}")
    }

    func testReflowRejectsEmptyContainers() {
        XCTAssertNil(JSONReflow.reflow("{}"))
        XCTAssertNil(JSONReflow.reflow("[]"))
        XCTAssertNil(JSONReflow.reflow("  {\n}  "))
        XCTAssertNil(JSONReflow.reflow("[ ]"))
    }

    func testReflowKeepsNonEmptyContainerWithEmptyChild() {
        XCTAssertEqual(JSONReflow.reflow(#"{"a":{}}"#)?.pretty, "{\n  \"a\": {}\n}")
        XCTAssertEqual(JSONReflow.reflow("[0]")?.pretty, "[\n  0\n]")
    }

    func testReflowIgnoresStructuralCharsInsideStrings() {
        let r = JSONReflow.reflow(#"{"u":"http://x/y","s":"a,b:{c}"}"#)
        XCTAssertEqual(r?.pretty, "{\n  \"u\": \"http://x/y\",\n  \"s\": \"a,b:{c}\"\n}")
        XCTAssertEqual(r?.compact, #"{"u":"http://x/y","s":"a,b:{c}"}"#)
    }

    func testReflowHandlesEscapedQuotes() {
        let r = JSONReflow.reflow(#"{"q":"he said \"hi\""}"#)
        XCTAssertEqual(r?.compact, #"{"q":"he said \"hi\""}"#)
        XCTAssertEqual(r?.pretty, "{\n  \"q\": \"he said \\\"hi\\\"\"\n}")
    }

    func testReflowPreservesUnicode() {
        XCTAssertEqual(JSONReflow.reflow(#"{"name":"café ☕"}"#)?.pretty, "{\n  \"name\": \"café ☕\"\n}")
    }

    func testReflowRejectsNonJSON() {
        XCTAssertNil(JSONReflow.reflow(""))
        XCTAssertNil(JSONReflow.reflow("hello world"))
        XCTAssertNil(JSONReflow.reflow("42"))           // a bare scalar isn't a body
        XCTAssertNil(JSONReflow.reflow("{bad json"))
    }

    // MARK: - JSONReflow.extractFirstJSON

    func testExtractJSONAtEnd() {
        let r = JSONReflow.extractFirstJSON(#"{"a":1}"#)
        XCTAssertEqual(r?.json, #"{"a":1}"#)
        XCTAssertEqual(r?.rest, "")
    }

    func testExtractJSONWithTrailingText() {
        let r = JSONReflow.extractFirstJSON("{\"a\":1}\nEND\nDuration: 5ms")
        XCTAssertEqual(r?.json, #"{"a":1}"#)
        XCTAssertEqual(r?.rest, "\nEND\nDuration: 5ms")
    }

    func testExtractJSONIgnoresBracesInStrings() {
        let r = JSONReflow.extractFirstJSON(#"{"s":"}]"}trailing"#)
        XCTAssertEqual(r?.json, #"{"s":"}]"}"#)
        XCTAssertEqual(r?.rest, "trailing")
    }

    func testExtractJSONNilWhenNoLeadingJSON() {
        XCTAssertNil(JSONReflow.extractFirstJSON("no json here"))
        XCTAssertNil(JSONReflow.extractFirstJSON(""))
    }

    // MARK: - Inline shape (one multi-line log → JSON lifted into its own entry)

    func testInlineBodySplitIntoOwnEntry() {
        var p = LogBodyPrettifier()
        let out = p.transform(line("GET /x 200\nHeaders: a=b\nBODY START\n{\"a\":1}"))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].message, "GET /x 200\nHeaders: a=b\nBODY START")
        XCTAssertNil(out[0].bodyCompact)
        XCTAssertEqual(out[1].message, "{\n  \"a\": 1\n}")        // its own, copyable entry
        XCTAssertEqual(out[1].bodyCompact, #"{"a":1}"#)
    }

    func testInlineBodyWithTrailingTextSplitsIntoThree() {
        var p = LogBodyPrettifier()
        let out = p.transform(line("REQ\nBODY START\n{\"a\":1}\nEND OF BODY"))
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0].message, "REQ\nBODY START")
        XCTAssertEqual(out[1].message, "{\n  \"a\": 1\n}")
        XCTAssertEqual(out[2].message, "END OF BODY")
        XCTAssertNil(out[2].bodyCompact)
    }

    func testInlineEmptyBodyNotSplit() {
        var p = LogBodyPrettifier()
        let out = p.transform(line("REQ\nBODY START\n{}"))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].message, "REQ\nBODY START\n{}")     // left exactly as-is
        XCTAssertNil(out[0].bodyCompact)
    }

    func testInlineNonJSONBodyStillPeeledOntoOwnLine() {
        var p = LogBodyPrettifier()
        let out = p.transform(line("REQ\nBODY START\nplain text body"))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].message, "REQ\nBODY START")
        XCTAssertEqual(out[1].message, "plain text body")   // its own entry, just not prettified
        XCTAssertNil(out[1].bodyCompact)
    }

    func testInlineTruncatedJSONBodySplitButNotPrettified() {
        var p = LogBodyPrettifier()
        // Mirrors a logger that truncates the body (Content-Length > what's logged).
        let out = p.transform(line("RESPONSE 200\nBODY START\n{\"company_id\":\"x\",\"report_create<…>"))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].message, "RESPONSE 200\nBODY START")
        XCTAssertEqual(out[1].message, "{\"company_id\":\"x\",\"report_create<…>")
        XCTAssertNil(out[1].bodyCompact)   // unbalanced/invalid JSON → left as plain text
    }

    func testInlineEmptyBodyTrailingNewlineDoesNotLeak() {
        var p = LogBodyPrettifier()
        let a = p.transform(line("BODY START\n"))   // empty inline body
        XCTAssertEqual(a.count, 1)
        XCTAssertNil(a[0].bodyCompact)
        let b = p.transform(line(#"{"a":1}"#))      // unrelated next line must NOT be a body
        XCTAssertEqual(b.count, 1)
        XCTAssertNil(b[0].bodyCompact)
    }

    // MARK: - Split shape (BODY START line, JSON in the next log — already its own entry)

    func testSplitBodyPrettifiedInPlace() {
        var p = LogBodyPrettifier()
        XCTAssertEqual(p.transform(line("BODY START")).count, 1)   // the marker line is untouched
        let body = p.transform(line(#"{"a":1,"b":2}"#))
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(body[0].message, "{\n  \"a\": 1,\n  \"b\": 2\n}")
        XCTAssertEqual(body[0].bodyCompact, #"{"a":1,"b":2}"#)
    }

    func testSplitWithPrefixedMarkerLine() {
        var p = LogBodyPrettifier()
        _ = p.transform(line("Response headers…\nBODY START"))
        let body = p.transform(line("[1,2]"))
        XCTAssertEqual(body[0].message, "[\n  1,\n  2\n]")
    }

    func testSplitEmptyBodyUntouched() {
        var p = LogBodyPrettifier()
        _ = p.transform(line("BODY START"))
        let body = p.transform(line("{}"))
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(body[0].message, "{}")
        XCTAssertNil(body[0].bodyCompact)
    }

    func testSplitNonJSONBodyUntouched() {
        var p = LogBodyPrettifier()
        _ = p.transform(line("BODY START"))
        let body = p.transform(line("not json at all"))
        XCTAssertEqual(body[0].message, "not json at all")
        XCTAssertNil(body[0].bodyCompact)
    }

    func testMarkerBetweenPairDoesNotBreakIt() {
        var p = LogBodyPrettifier()
        _ = p.transform(line("BODY START"))
        let injected = p.transform(line("✓ reconnected", isMarker: true))
        XCTAssertNil(injected[0].bodyCompact)
        let body = p.transform(line(#"{"a":1}"#))
        XCTAssertEqual(body[0].bodyCompact, #"{"a":1}"#)   // pair survived the synthetic marker
    }

    func testPlainJSONLineWithoutMarkerIsUntouched() {
        var p = LogBodyPrettifier()
        let out = p.transform(line(#"{"a":1}"#))   // valid JSON, but no BODY START preceding it
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0].bodyCompact)
    }

    func testBodyStartAsSubstringIsNotAMarkerLine() {
        var p = LogBodyPrettifier()
        let out = p.transform(line("the BODY START marker is documented here"))
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0].bodyCompact)
        let next = p.transform(line(#"{"a":1}"#))   // must not have armed the next line
        XCTAssertNil(next[0].bodyCompact)
    }

    // MARK: - JSONReflow.scan (incremental validator)

    func testScanComplete() {
        XCTAssertEqual(JSONReflow.scan(Array(#"{"a":1}"#.utf8)), .complete(end: 7))
        XCTAssertEqual(JSONReflow.scan(Array("[1,2]".utf8)), .complete(end: 5))
        XCTAssertEqual(JSONReflow.scan(Array(#"{"a":1} trailing"#.utf8)), .complete(end: 7))
    }

    func testScanIncomplete() {
        XCTAssertEqual(JSONReflow.scan(Array(#"{"a":1,"#.utf8)), .incomplete)   // mid-object
        XCTAssertEqual(JSONReflow.scan(Array(#"{"a":"unterm"#.utf8)), .incomplete) // open string
        XCTAssertEqual(JSONReflow.scan(Array(#"{"a":tru"#.utf8)), .incomplete)   // partial literal
        XCTAssertEqual(JSONReflow.scan(Array("[1,2".utf8)), .incomplete)
        XCTAssertEqual(JSONReflow.scan(Array("".utf8)), .incomplete)
        XCTAssertEqual(JSONReflow.scan(Array("   ".utf8)), .incomplete)
    }

    func testScanInvalid() {
        XCTAssertEqual(JSONReflow.scan(Array("nope".utf8)), .invalid)
        XCTAssertEqual(JSONReflow.scan(Array(#"{"a":zzz}"#.utf8)), .invalid)     // bad token
        XCTAssertEqual(JSONReflow.scan(Array(#"{"a":1 "b":2}"#.utf8)), .invalid) // missing comma
    }

    // MARK: - Chunked reassembly (body split across consecutive entries)

    func testInlineChunkedBodyReassembled() {
        var p = LogBodyPrettifier()
        let r1 = p.transform(line("RESPONSE 200\nBODY START\n{\"a\":1,"))
        XCTAssertEqual(r1.map(\.message), ["RESPONSE 200\nBODY START"])   // head out, body held
        XCTAssertEqual(p.transform(line(#""b":2,"#)).count, 0)            // held
        let r3 = p.transform(line(#""c":3}"#))
        XCTAssertEqual(r3.count, 1)
        XCTAssertEqual(r3[0].message, "{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}")
        XCTAssertEqual(r3[0].bodyCompact, #"{"a":1,"b":2,"c":3}"#)
    }

    func testSplitChunkedBodyReassembled() {
        var p = LogBodyPrettifier()
        XCTAssertEqual(p.transform(line("headers…\nBODY START")).count, 1)  // marker line out
        XCTAssertEqual(p.transform(line("[1,")).count, 0)                   // body start, held
        let last = p.transform(line("2,3]"))
        XCTAssertEqual(last.count, 1)
        XCTAssertEqual(last[0].message, "[\n  1,\n  2,\n  3\n]")
        XCTAssertEqual(last[0].bodyCompact, "[1,2,3]")
    }

    func testChunkBreakMidStringReassembled() {
        var p = LogBodyPrettifier()
        _ = p.transform(line("BODY START"))
        XCTAssertEqual(p.transform(line(#"{"url":"https://exa"#)).count, 0)  // cut mid-string value
        let done = p.transform(line(#"mple.com/x"}"#))
        XCTAssertEqual(done[0].message, "{\n  \"url\": \"https://example.com/x\"\n}")
    }

    func testNonContinuationEndsBodyAndIsReprocessed() {
        var p = LogBodyPrettifier()
        _ = p.transform(line("h\nBODY START\n{\"a\":1,"))   // head out, accumulate {"a":1,
        // The next same-tag log isn't a JSON continuation → flush body as plain, process it.
        let out = p.transform(line("RESPONSE 200 OK"))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].message, #"{"a":1,"#)          // flushed (unfinished) body, plain
        XCTAssertNil(out[0].bodyCompact)
        XCTAssertEqual(out[1].message, "RESPONSE 200 OK")
    }

    func testDifferentTagEndsAccumulation() {
        var p = LogBodyPrettifier()
        _ = p.transform(line("h\nBODY START\n{\"a\":1,"))
        let out = p.transform(line("unrelated", tag: "OtherTag"))
        XCTAssertEqual(out.map(\.message), [#"{"a":1,"#, "unrelated"])
    }

    func testTruncatedBodyDoesNotAccumulate() {
        var p = LogBodyPrettifier()
        // OS-truncated body (`<…>`): unterminated, but no continuation is coming.
        let out = p.transform(line("RESPONSE 200\nBODY START\n{\"company_id\":\"x\",\"report_create<…>"))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].message, "RESPONSE 200\nBODY START")
        XCTAssertEqual(out[1].message, "{\"company_id\":\"x\",\"report_create<…>")
        XCTAssertNil(out[1].bodyCompact)   // not held, not prettified — peeled as-is
    }

    func testFinalizeEmitsHeldBody() {
        var p = LogBodyPrettifier()
        _ = p.transform(line("h\nBODY START\n{\"a\":1,"))   // accumulating
        let fin = p.finalize()
        XCTAssertEqual(fin.count, 1)
        XCTAssertEqual(fin[0].message, #"{"a":1,"#)
        XCTAssertNil(fin[0].bodyCompact)
        XCTAssertTrue(p.finalize().isEmpty)   // nothing left after
    }
}
