import SwiftUI
import Lemonade

/// Ordered JSON value (preserves object key order, unlike JSONSerialization).
indirect enum JSONValue {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    var isContainer: Bool {
        switch self { case .object, .array: return true; default: return false }
    }
    var childCount: Int {
        switch self {
        case .object(let m): return m.count
        case .array(let a): return a.count
        default: return 0
        }
    }
}

/// Tiny recursive-descent JSON parser. Returns a value only when the root is an
/// object or array (so we don't offer the tree view for plain text/numbers).
enum JSONParse {
    static func parse(_ data: Data?) -> JSONValue? {
        guard let data, let s = String(data: data, encoding: .utf8) else { return nil }
        return parse(text: s)
    }

    static func parse(text: String) -> JSONValue? {
        var p = Parser(Array(text))
        p.skipWS()
        guard let v = p.value() else { return nil }
        switch v { case .object, .array: return v; default: return nil }
    }

    private struct Parser {
        let s: [Character]
        var i = 0
        init(_ s: [Character]) { self.s = s }

        mutating func skipWS() {
            while i < s.count, s[i] == " " || s[i] == "\n" || s[i] == "\t" || s[i] == "\r" { i += 1 }
        }
        var cur: Character? { i < s.count ? s[i] : nil }

        mutating func value() -> JSONValue? {
            skipWS()
            switch cur {
            case "{": return object()
            case "[": return array()
            case "\"": return string().map { .string($0) }
            case "t", "f": return bool()
            case "n": return null()
            case .some(let c) where c == "-" || c.isNumber: return number()
            default: return nil
            }
        }

        mutating func object() -> JSONValue? {
            i += 1  // {
            var entries: [(key: String, value: JSONValue)] = []
            skipWS()
            if cur == "}" { i += 1; return .object(entries) }
            while true {
                skipWS()
                guard cur == "\"", let key = string() else { return nil }
                skipWS()
                guard cur == ":" else { return nil }
                i += 1
                guard let v = value() else { return nil }
                entries.append((key, v))
                skipWS()
                if cur == "," { i += 1; continue }
                if cur == "}" { i += 1; return .object(entries) }
                return nil
            }
        }

        mutating func array() -> JSONValue? {
            i += 1  // [
            var items: [JSONValue] = []
            skipWS()
            if cur == "]" { i += 1; return .array(items) }
            while true {
                guard let v = value() else { return nil }
                items.append(v)
                skipWS()
                if cur == "," { i += 1; continue }
                if cur == "]" { i += 1; return .array(items) }
                return nil
            }
        }

        mutating func string() -> String? {
            guard cur == "\"" else { return nil }
            i += 1
            var out = ""
            while i < s.count {
                let c = s[i]; i += 1
                if c == "\"" { return out }
                if c == "\\" {
                    guard i < s.count else { return nil }
                    let e = s[i]; i += 1
                    switch e {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "u":
                        let hex = String(s[i..<min(i + 4, s.count)])
                        i += 4
                        if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                            out.unicodeScalars.append(scalar)
                        }
                    default: out.append(e)
                    }
                } else {
                    out.append(c)
                }
            }
            return nil
        }

        mutating func number() -> JSONValue? {
            let start = i
            while i < s.count, "0123456789+-.eE".contains(s[i]) { i += 1 }
            guard i > start else { return nil }
            return .number(String(s[start..<i]))
        }

        mutating func bool() -> JSONValue? {
            if match("true") { return .bool(true) }
            if match("false") { return .bool(false) }
            return nil
        }
        mutating func null() -> JSONValue? { match("null") ? .null : nil }

        mutating func match(_ word: String) -> Bool {
            let chars = Array(word)
            guard i + chars.count <= s.count, Array(s[i..<i + chars.count]) == chars else { return false }
            i += chars.count
            return true
        }
    }
}

/// Collapsible JSON tree. Objects/arrays get a +/- toggle to open/close blocks —
/// useful for navigating large payloads.
struct JSONTreeView: View {
    let value: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            JSONNode(key: nil, value: value, depth: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct JSONNode: View {
    let key: String?
    let value: JSONValue
    let depth: Int
    @State private var expanded: Bool

    init(key: String?, value: JSONValue, depth: Int) {
        self.key = key
        self.value = value
        self.depth = depth
        _expanded = State(initialValue: depth < 2)   // open top levels, collapse deeper
    }

    private let font = LogLevelStyle.mono(11)

    var body: some View {
        if value.isContainer {
            if value.childCount == 0 {
                // Empty container: show both brackets inline, no toggle.
                HStack(spacing: 4) {
                    placeholderIcon
                    if let key { keyText(key); colon }
                    Text(isObject ? "{ }" : "[ ]").font(font)
                        .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Button(action: { expanded.toggle() }) {
                        HStack(spacing: 4) {
                            Image(systemName: expanded ? "minus.square" : "plus.square")
                                .font(.system(size: 10))
                                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                            if let key { keyText(key); colon }
                            Text(expanded ? openBracket : collapsedSummary)
                                .font(font)
                                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if expanded {
                        VStack(alignment: .leading, spacing: 1) { children }
                            .padding(.leading, 16)
                        HStack(spacing: 4) {
                            placeholderIcon
                            Text(closeBracket).font(font)
                                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 4) {
                placeholderIcon  // align with toggles
                if let key { keyText(key); colon }
                scalarText
            }
        }
    }

    private var isObject: Bool { if case .object = value { return true }; return false }
    private var openBracket: String { isObject ? "{" : "[" }
    private var closeBracket: String { isObject ? "}" : "]" }
    private var collapsedSummary: String {
        isObject ? "{ … } \(value.childCount)" : "[ … ] \(value.childCount)"
    }
    private var placeholderIcon: some View {
        Image(systemName: "minus.square").font(.system(size: 10)).opacity(0)
    }
    private var colon: some View {
        Text(":").font(font).foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
    }

    @ViewBuilder private var children: some View {
        switch value {
        case .object(let entries):
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                JSONNode(key: entry.key, value: entry.value, depth: depth + 1)
            }
        case .array(let items):
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                JSONNode(key: String(idx), value: item, depth: depth + 1)
            }
        default: EmptyView()
        }
    }

    private func keyText(_ k: String) -> some View {
        Text(k).font(font).foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
    }

    @ViewBuilder private var scalarText: some View {
        switch value {
        case .string(let v):
            Text("\"\(v)\"").font(font).foregroundStyle(LemonadeTheme.colors.content.contentPositive)
                .textSelection(.enabled)
        case .number(let v):
            Text(v).font(font).foregroundStyle(LemonadeTheme.colors.content.contentInfo)
        case .bool(let v):
            Text(v ? "true" : "false").font(font).foregroundStyle(LemonadeTheme.colors.content.contentBrand)
        case .null:
            Text("null").font(font).foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
        default: EmptyView()
        }
    }
}
