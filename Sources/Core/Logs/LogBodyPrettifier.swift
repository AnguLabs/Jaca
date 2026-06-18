import Foundation

/// Detects KMP endpoint **response bodies** in the log stream and reflows their JSON
/// into indented, multi-line text — so a click-drag selects the whole body — while
/// keeping a one-line compact rendering for the double-click "collapse" view.
///
/// Shapes recognised, all anchored on a `BODY START` line:
///   1. **inline** — one log carrying the request/response metadata *and* the body
///      (`…\nBODY START\n{json}`). The JSON is lifted into its **own** log entry.
///   2. **split**  — one log ending in a bare `BODY START` line, then a separate log with
///      the `{json}`. The JSON is already its own entry, so it's just prettified.
///   3. **chunked** — the body is spread across several consecutive entries because the
///      app's logger splits long messages (e.g. Kermit's `ChunkedLogWriter`, or to dodge
///      `os_log`'s ~1 KB cap). The fragments are buffered and merged into one entry.
///
/// Reassembly is driven by `JSONReflow.scan`: after a body starts, each following entry
/// from the **same logger** (matching tag + level) is appended and re-scanned —
/// `.incomplete` keeps waiting, `.complete` emits the merged/prettified body (any trailing
/// text becomes its own entry), and `.invalid` means that entry is *not* part of the body,
/// so the (unfinished) body is flushed as-is and the entry is processed normally.
///
/// Stateful + order-sensitive: feed it every line once, in arrival order (from the
/// session's flush). Empty (`{}` / `[]`) or non-JSON bodies are left untouched. Synthetic
/// markers pass through transparently. `transform` returns 0+ lines: `[]` while holding
/// mid-body, `[line]` unchanged, or the split/merged entries.
struct LogBodyPrettifier {
    /// The line that precedes a response body in every shape.
    static let marker = "BODY START"
    /// Backstop so a body that never validates (truncated mid-stream, not really JSON)
    /// can't buffer without bound.
    private static let maxAccumulatedBytes = 4_000_000

    private enum State {
        case idle
        /// A bare `BODY START` line was seen; the next line begins the body (split shape).
        case expectingBody
        /// Collecting a JSON body spread across entries. `proto` carries the metadata
        /// (tag/level/timestamp) the merged entry inherits.
        case accumulating(proto: LogLine, json: String, bytes: Int)
    }
    private var state: State = .idle

    /// Returns the line(s) this one becomes (see the type doc). `[]` means "held — part of
    /// a body still being reassembled".
    mutating func transform(_ line: LogLine) -> [LogLine] {
        guard !line.isMarker else { return [line] }   // synthetic; never a body, never breaks a pair

        if case .accumulating(let proto, let json, let bytes) = state {
            return continueBody(proto: proto, json: json, bytes: bytes, line: line)
        }

        if case .expectingBody = state {
            state = .idle
            return beginBody(head: nil, bodyText: line.message, line: line)
        }

        // Fast path: lines that can't be (the start of) a body need no work.
        guard line.message.contains(Self.marker) else { return [line] }

        let lines = line.message.split(separator: "\n", omittingEmptySubsequences: false)
        guard let markerIdx = lines.lastIndex(where: { isMarkerLine($0) }) else { return [line] }
        if markerIdx == lines.count - 1 {
            // `BODY START` is the final line → the body is the next log (split shape).
            state = .expectingBody
            return [line]
        }
        // Inline shape: metadata + BODY START, then the body, in one message.
        let head = lines[...markerIdx].joined(separator: "\n")
        let afterText = lines[(markerIdx + 1)...].joined(separator: "\n")
        return beginBody(head: part(line, message: head, raw: head, compact: nil),
                         bodyText: afterText, line: line)
    }

    /// Emit any half-reassembled body (call when the stream stops) so held fragments
    /// aren't lost.
    mutating func finalize() -> [LogLine] {
        guard case .accumulating(let proto, let json, _) = state else { return [] }
        state = .idle
        return [part(proto, message: json, raw: json, compact: nil)]
    }

    // MARK: -

    /// Starts handling the text after `BODY START`. `head` is the metadata entry to emit
    /// first (inline shape) or nil (split shape, where the marker line stands alone).
    private mutating func beginBody(head: LogLine?, bodyText: String, line: LogLine) -> [LogLine] {
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty (`{}`/`[]`) or absent body: nothing to lift — leave the log exactly as it
        // was (whole inline line, or the split body line as-is).
        guard !trimmed.isEmpty, trimmed != "{}", trimmed != "[]" else {
            state = .idle
            return [line]
        }
        switch JSONReflow.scan(Array(bodyText.utf8)) {
        case .complete:
            state = .idle
            return emitBody(proto: line, head: head, fullText: bodyText)
                ?? peel(head: head, body: bodyText, line: line)
        case .incomplete where JSONReflow.startsWithContainer(bodyText) && !looksTruncated(bodyText):
            // A JSON object/array that isn't finished in this entry → keep collecting the
            // following entries (e.g. a logger that chunks long messages).
            state = .accumulating(proto: line, json: bodyText, bytes: bodyText.utf8.count)
            return head.map { [$0] } ?? []
        case .incomplete, .invalid:
            // Not JSON, a bare unfinished scalar, or an OS-truncated body (`…`/`<…>`, where
            // the rest is gone) → just peel it onto its own line, don't wait for more.
            return peel(head: head, body: bodyText, line: line)
        }
    }

    /// Appends `line` to the body being reassembled, or ends the body if `line` isn't a
    /// continuation.
    private mutating func continueBody(proto: LogLine, json: String, bytes: Int, line: LogLine) -> [LogLine] {
        // Continuations come from the same logger call sequence, so they share tag+level.
        // A different tag/level (or a runaway buffer) means the body is over.
        guard line.tag == proto.tag, line.level == proto.level, bytes < Self.maxAccumulatedBytes else {
            state = .idle
            return [part(proto, message: json, raw: json, compact: nil)] + transform(line)
        }
        let candidate = json + line.message
        switch JSONReflow.scan(Array(candidate.utf8)) {
        case .complete:
            state = .idle
            return emitBody(proto: proto, head: nil, fullText: candidate)
                ?? [part(proto, message: candidate, raw: candidate, compact: nil)]
        case .incomplete where looksTruncated(candidate):
            // This chunk got OS-truncated (`…`/`<…>`) — the rest is gone. `line` is still
            // part of the body, so emit the merged-so-far text (incl. it) as plain.
            state = .idle
            return [part(proto, message: candidate, raw: candidate, compact: nil)]
        case .incomplete:
            state = .accumulating(proto: proto, json: candidate, bytes: candidate.utf8.count)
            return []
        case .invalid:
            // `line` isn't part of the body → flush what we have, then process it fresh.
            state = .idle
            return [part(proto, message: json, raw: json, compact: nil)] + transform(line)
        }
    }

    /// Builds the prettified body entry (+ a trailing entry for any text after the JSON)
    /// from a complete `fullText`, prepending `head` when present. The body/tail entries
    /// inherit `proto`'s metadata (tag/level/timestamp). `nil` when the balanced span
    /// isn't actually valid JSON, so the caller falls back to plain text.
    private func emitBody(proto: LogLine, head: LogLine?, fullText: String) -> [LogLine]? {
        guard let (jsonStr, rest) = JSONReflow.extractFirstJSON(fullText),
              let r = JSONReflow.reflow(jsonStr) else { return nil }
        var parts: [LogLine] = []
        if let head { parts.append(head) }
        parts.append(part(proto, message: r.pretty, raw: jsonStr, compact: r.compact))
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(part(proto, message: tail, raw: tail, compact: nil)) }
        return parts
    }

    /// Peels the body onto its own entry without prettifying (truncated / non-JSON), or
    /// leaves the split body line as-is when there's no separate head.
    private func peel(head: LogLine?, body: String, line: LogLine) -> [LogLine] {
        if let head { return [head, part(line, message: body, raw: body, compact: nil)] }
        return [line]
    }

    private func isMarkerLine(_ s: Substring) -> Bool {
        String(s).trimmingCharacters(in: .whitespacesAndNewlines) == Self.marker
    }

    /// Whether `text` ends with a truncation marker the OS/logger appends when it cut the
    /// message (e.g. `os_log`'s ~1 KB cap shows `<…>`). Such a body has no continuation
    /// coming, so we must not sit waiting for more chunks.
    private func looksTruncated(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasSuffix("…") || t.hasSuffix("…>") || t.hasSuffix("...") || t.hasSuffix("...>")
    }

    /// Builds a derived entry from `line`'s metadata with new text. (`message` is `let` on
    /// `LogLine`.) The session re-stamps the seq.
    private func part(_ line: LogLine, message: String, raw: String, compact: String?) -> LogLine {
        LogLine(seq: line.seq, timestamp: line.timestamp, level: line.level,
                tag: line.tag, pid: line.pid, tid: line.tid,
                message: message, raw: raw, processName: line.processName,
                isMarker: line.isMarker, markerCritical: line.markerCritical,
                isConsoleOutput: line.isConsoleOutput, bodyCompact: compact)
    }
}
