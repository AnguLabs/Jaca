import XCTest
@testable import Squeeze

final class JSONParseTests: XCTestCase {
    func testParsesObjectPreservingOrderAndTypes() {
        let json = #"{"b":1,"a":"x","n":null,"ok":true,"arr":[1,2,{"k":3}]}"#
        guard case let .object(entries)? = JSONParse.parse(text: json) else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(entries.map(\.key), ["b", "a", "n", "ok", "arr"])  // insertion order kept
        if case .number(let v) = entries[0].value { XCTAssertEqual(v, "1") } else { XCTFail() }
        if case .string(let v) = entries[1].value { XCTAssertEqual(v, "x") } else { XCTFail() }
        if case .null = entries[2].value {} else { XCTFail("null") }
        if case .bool(let v) = entries[3].value { XCTAssertTrue(v) } else { XCTFail() }
        if case .array(let a) = entries[4].value { XCTAssertEqual(a.count, 3) } else { XCTFail() }
    }

    func testParsesArrayRoot() {
        guard case let .array(items)? = JSONParse.parse(text: "[1, \"two\", false]") else {
            return XCTFail("expected array")
        }
        XCTAssertEqual(items.count, 3)
    }

    func testHandlesEscapesAndUnicode() {
        guard case let .object(e)? = JSONParse.parse(text: #"{"s":"a\nb\"cA"}"#),
              case let .string(v) = e[0].value else { return XCTFail() }
        XCTAssertEqual(v, "a\nb\"cA")
    }

    func testRejectsNonJSONAndScalars() {
        XCTAssertNil(JSONParse.parse(text: "hello world"))
        XCTAssertNil(JSONParse.parse(text: "42"))          // scalar root → no tree
        XCTAssertNil(JSONParse.parse(text: "<html></html>"))
        XCTAssertNil(JSONParse.parse(text: ""))
    }
}
