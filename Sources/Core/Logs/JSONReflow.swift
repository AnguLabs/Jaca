import Foundation

/// Reformats a JSON string into an indented (multi-line) form and a minified
/// (single-line) form, **preserving key order** — it re-flows the original token
/// stream rather than round-tripping through a dictionary (which `JSONSerialization`
/// would sort/relabel). For a streamed endpoint response the server's field order is
/// part of what you're reading, so we keep it.
///
/// Pure + testable. Also provides `scan`, an incremental validator that tells the body
/// detector whether accumulated text is a complete JSON value, a valid-but-unfinished
/// prefix, or already invalid — which is what lets it stitch a body back together when a
/// logger (e.g. Kermit's `ChunkedLogWriter`) splits it across several log entries.
///
/// Everything works on UTF-8 bytes: every structural byte is ASCII and can't collide
/// with a UTF-8 continuation byte (those are all ≥ 0x80), so byte scanning is both
/// correct and cheap even for very large payloads.
enum JSONReflow {
    /// `nil` when `raw` isn't a JSON object/array, or is an **empty** one (`{}` / `[]`):
    /// an empty body has nothing to expand, so it's left exactly as-is. Otherwise the
    /// indented and minified renderings, key order intact.
    static func reflow(_ raw: String) -> (pretty: String, compact: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first,
              first == "{" || first == "[" else { return nil }
        guard let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        let bytes = Array(trimmed.utf8)
        let compact = String(decoding: minify(bytes), as: UTF8.self)
        guard compact != "{}", compact != "[]" else { return nil }   // empty body → leave it
        return (pretty: String(decoding: prettify(bytes), as: UTF8.self), compact: compact)
    }

    /// Finds the first complete JSON object/array in `text` (skipping only leading
    /// whitespace) and returns it together with whatever follows it. `nil` when `text`
    /// doesn't contain a complete leading JSON value.
    static func extractFirstJSON(_ text: String) -> (json: String, rest: String)? {
        let bytes = Array(text.utf8)
        guard case .complete(let end) = scan(bytes) else { return nil }
        var start = 0
        while start < bytes.count, isWhitespace(bytes[start]) { start += 1 }
        return (json: String(decoding: bytes[start..<end], as: UTF8.self),
                rest: end < bytes.count ? String(decoding: bytes[end...], as: UTF8.self) : "")
    }

    /// Whether `text` (after leading whitespace) begins a JSON object or array — the only
    /// thing the body detector will try to accumulate across entries.
    static func startsWithContainer(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count, isWhitespace(bytes[i]) { i += 1 }
        return i < bytes.count && (bytes[i] == openBrace || bytes[i] == openBracket)
    }

    // MARK: - Incremental validation

    /// The verdict on whether `bytes` is (the start of) a single JSON value.
    enum Scan: Equatable {
        /// A complete top-level value occupies the bytes up to `end` (exclusive); any
        /// bytes after `end` are trailing content.
        case complete(end: Int)
        /// A valid JSON prefix that simply isn't finished yet — feed more and re-scan.
        case incomplete
        /// The grammar is violated; this can never become valid JSON.
        case invalid
    }

    /// Incrementally classifies `bytes`. This is what makes chunk reassembly safe:
    /// appending the *next* log line and re-scanning yields `.complete` (done — the JSON
    /// closed), `.incomplete` (keep waiting for more chunks), or `.invalid` (the line is
    /// **not** a continuation, so the body ended and that line is a separate log).
    static func scan(_ bytes: [UInt8]) -> Scan {
        var i = 0
        skipWS(bytes, &i)
        guard i < bytes.count else { return .incomplete }   // only whitespace so far
        do {
            try scanValue(bytes, &i, depth: 0)
            return .complete(end: i)
        } catch Signal.incomplete {
            return .incomplete
        } catch {
            return .invalid
        }
    }

    private enum Signal: Error { case incomplete, invalid }

    private static func skipWS(_ b: [UInt8], _ i: inout Int) {
        while i < b.count, isWhitespace(b[i]) { i += 1 }
    }

    private static func scanValue(_ b: [UInt8], _ i: inout Int, depth: Int) throws {
        if depth > 512 { throw Signal.invalid }            // pathological nesting
        skipWS(b, &i)
        guard i < b.count else { throw Signal.incomplete }
        switch b[i] {
        case openBrace:   try scanObject(b, &i, depth: depth)
        case openBracket: try scanArray(b, &i, depth: depth)
        case quote:       try scanString(b, &i)
        case 0x74, 0x66, 0x6E: try scanWord(b, &i)         // true / false / null
        case 0x2D, 0x30...0x39: try scanNumber(b, &i)      // '-' or a digit
        default: throw Signal.invalid
        }
    }

    private static func scanObject(_ b: [UInt8], _ i: inout Int, depth: Int) throws {
        i += 1                                              // consume '{'
        skipWS(b, &i)
        guard i < b.count else { throw Signal.incomplete }
        if b[i] == closeBrace { i += 1; return }            // {}
        while true {
            skipWS(b, &i)
            guard i < b.count else { throw Signal.incomplete }
            guard b[i] == quote else { throw Signal.invalid }   // key must be a string
            try scanString(b, &i)
            skipWS(b, &i)
            guard i < b.count else { throw Signal.incomplete }
            guard b[i] == colon else { throw Signal.invalid }
            i += 1
            try scanValue(b, &i, depth: depth + 1)
            skipWS(b, &i)
            guard i < b.count else { throw Signal.incomplete }
            if b[i] == comma { i += 1; continue }
            if b[i] == closeBrace { i += 1; return }
            throw Signal.invalid
        }
    }

    private static func scanArray(_ b: [UInt8], _ i: inout Int, depth: Int) throws {
        i += 1                                              // consume '['
        skipWS(b, &i)
        guard i < b.count else { throw Signal.incomplete }
        if b[i] == closeBracket { i += 1; return }          // []
        while true {
            try scanValue(b, &i, depth: depth + 1)
            skipWS(b, &i)
            guard i < b.count else { throw Signal.incomplete }
            if b[i] == comma { i += 1; continue }
            if b[i] == closeBracket { i += 1; return }
            throw Signal.invalid
        }
    }

    private static func scanString(_ b: [UInt8], _ i: inout Int) throws {
        i += 1                                              // consume opening quote
        while i < b.count {
            let c = b[i]
            if c == backslash {
                i += 1
                guard i < b.count else { throw Signal.incomplete }   // escape needs its char
                i += 1
                continue
            }
            if c == quote { i += 1; return }
            i += 1
        }
        throw Signal.incomplete                              // no closing quote yet
    }

    private static func scanNumber(_ b: [UInt8], _ i: inout Int) throws {
        let start = i
        if i < b.count, b[i] == 0x2D { i += 1 }              // optional '-'
        func digits() { while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 } }
        digits()
        if i < b.count, b[i] == 0x2E { i += 1; digits() }    // fraction
        if i < b.count, b[i] == 0x65 || b[i] == 0x45 {       // exponent
            i += 1
            if i < b.count, b[i] == 0x2B || b[i] == 0x2D { i += 1 }
            digits()
        }
        if i == start { throw Signal.invalid }
        // A number that runs to the very end might still be growing (e.g. "12" before
        // "34" arrives in the next chunk) — treat as an unfinished prefix.
        if i >= b.count { throw Signal.incomplete }
    }

    private static func scanWord(_ b: [UInt8], _ i: inout Int) throws {
        for word in [trueWord, falseWord, nullWord] where b[i] == word[0] {
            var k = 0
            while k < word.count {
                guard i + k < b.count else { i = b.count; throw Signal.incomplete }
                guard b[i + k] == word[k] else { throw Signal.invalid }
                k += 1
            }
            i += word.count
            return
        }
        throw Signal.invalid
    }

    private static let trueWord = Array("true".utf8)
    private static let falseWord = Array("false".utf8)
    private static let nullWord = Array("null".utf8)

    // ASCII bytes we act on; everything else (incl. UTF-8 continuation bytes) is copied.
    private static let quote: UInt8 = 0x22         // "
    private static let backslash: UInt8 = 0x5C     // \
    private static let openBrace: UInt8 = 0x7B     // {
    private static let closeBrace: UInt8 = 0x7D    // }
    private static let openBracket: UInt8 = 0x5B   // [
    private static let closeBracket: UInt8 = 0x5D  // ]
    private static let colon: UInt8 = 0x3A         // :
    private static let comma: UInt8 = 0x2C         // ,
    private static let space: UInt8 = 0x20
    private static let newline: UInt8 = 0x0A

    private static func isWhitespace(_ b: UInt8) -> Bool {
        b == space || b == 0x09 || b == 0x0A || b == 0x0D
    }

    /// Drops insignificant whitespace (outside strings) — one compact line.
    private static func minify(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(bytes.count)
        var inString = false, escaped = false
        for b in bytes {
            if inString {
                out.append(b)
                if escaped { escaped = false }
                else if b == backslash { escaped = true }
                else if b == quote { inString = false }
            } else if isWhitespace(b) {
                continue
            } else {
                if b == quote { inString = true }
                out.append(b)
            }
        }
        return out
    }

    /// Re-indents with two spaces per depth level. Assumes well-formed JSON (validated
    /// by `reflow`). Empty objects/arrays stay on one line (`{}` / `[]`).
    private static func prettify(_ bytes: [UInt8], indent: Int = 2) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(bytes.count + bytes.count / 2)
        var depth = 0, inString = false, escaped = false
        var i = 0; let n = bytes.count
        func breakLine(_ d: Int) {
            out.append(newline)
            out.append(contentsOf: repeatElement(space, count: d * indent))
        }
        while i < n {
            let b = bytes[i]
            if inString {
                out.append(b)
                if escaped { escaped = false }
                else if b == backslash { escaped = true }
                else if b == quote { inString = false }
                i += 1; continue
            }
            switch b {
            case space, 0x09, 0x0A, 0x0D:
                i += 1                                   // skip insignificant whitespace
            case quote:
                inString = true; out.append(b); i += 1
            case openBrace, openBracket:
                out.append(b)
                var j = i + 1
                while j < n, isWhitespace(bytes[j]) { j += 1 }
                let closer = (b == openBrace) ? closeBrace : closeBracket
                if j < n, bytes[j] == closer {           // empty container → keep inline
                    out.append(closer); i = j + 1
                } else {
                    depth += 1; breakLine(depth); i += 1
                }
            case closeBrace, closeBracket:
                depth -= 1; breakLine(depth); out.append(b); i += 1
            case comma:
                out.append(b); breakLine(depth); i += 1
            case colon:
                out.append(colon); out.append(space); i += 1
            default:
                out.append(b); i += 1
            }
        }
        return out
    }
}
