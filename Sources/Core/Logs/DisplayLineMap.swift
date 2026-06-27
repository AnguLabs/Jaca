import Foundation

/// Splits a log message into the fixed-height **display rows** the virtualized list
/// renders it across — one row per `\n`-separated line — with a hard cap so a runaway
/// multi-thousand-line blob can't bury the list (or blow up a recycled cell's cache).
///
/// Pure + testable: `count` (cheap, no allocation) drives `DisplayLineMap`; the cell
/// caches `displayLines` once per assignment for drawing.
enum LogTextLines {
    /// Most we ever expand a single entry to. Comfortably covers real stack traces /
    /// pretty-printed payloads; the overflow collapses into one "… N more lines" row.
    static let maxPerEntry = 200

    /// Number of display rows for `message` (capped, always ≥ 1).
    static func count(_ message: String) -> Int {
        min(max(rawLineCount(message), 1), maxPerEntry)
    }

    /// `\n`-separated line count, ignoring a single trailing newline (so `"a\n"` is one
    /// line, not two). Always ≥ 1.
    static func rawLineCount(_ message: String) -> Int {
        let m = normalized(message)
        guard !m.isEmpty else { return 1 }
        var n = 1
        for scalar in m.unicodeScalars where scalar == "\n" { n += 1 }
        if m.hasSuffix("\n") { n -= 1 }
        return max(1, n)
    }

    /// True when `message` has more lines than we render (the last shown row is then a
    /// "… N more lines" indicator, but copy still yields the full message).
    static func isTruncated(_ message: String) -> Bool { rawLineCount(message) > maxPerEntry }

    /// The capped list of strings to draw, one per display row (count matches `count`).
    /// When truncated, the final entry is a synthetic indicator instead of a real line.
    /// Tabs are expanded to spaces so indentation (stack frames, pretty-printed bodies)
    /// renders reliably — `NSString.draw` has no paragraph style, so a raw `\t` falls back
    /// to unreliable default tab stops and often shows no indent at all.
    static func displayLines(_ message: String) -> [String] {
        var parts = normalized(message)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { expandingTabs(String($0)) }
        if parts.count > 1, parts.last == "" { parts.removeLast() }   // drop trailing-newline blank
        if parts.isEmpty { parts = [""] }
        guard parts.count > maxPerEntry else { return parts }
        let shown = Array(parts.prefix(maxPerEntry - 1))
        let hidden = parts.count - shown.count
        return shown + ["… \(hidden) more line\(hidden == 1 ? "" : "s") — ⌘C copies all"]
    }

    /// Collapse CRLF / lone CR so `\n` is the sole line break — Swift treats `\r\n` as a
    /// single grapheme, which would otherwise make the count and the split disagree.
    /// Allocation-free when there's no carriage return (the overwhelming common case).
    private static func normalized(_ message: String) -> String {
        message.utf8.contains(13) ? message.replacingOccurrences(of: "\r", with: "") : message
    }

    /// Tab width used when expanding `\t` to spaces for display (stack frames use one
    /// leading tab; 4 columns is the conventional, clearly-visible indent).
    static let tabWidth = 4

    /// Expands tabs to the next tab stop so indentation is visible and column-aligned.
    /// Allocation-free when the line has no tab (the overwhelming common case).
    static func expandingTabs(_ line: String) -> String {
        guard line.utf8.contains(9) else { return line }
        var out = ""
        out.reserveCapacity(line.count + tabWidth)
        var col = 0
        for ch in line {
            if ch == "\t" {
                let n = tabWidth - (col % tabWidth)
                out += String(repeating: " ", count: n)
                col += n
            } else {
                out.append(ch)
                col += 1
            }
        }
        return out
    }
}

/// Maps a fixed-row-height virtualized list's **display rows** to the multi-line log
/// entries behind them: each log occupies `lineCount` consecutive rows. This is what
/// lets the list render `\n` without giving up the uniform-row fast path — the row
/// count grows, the row height stays constant, so every scroll/trim calculation that
/// used `count × rowHeight` still holds, just in display-row units.
///
/// `prefix[i]` is the first display row of log `i` (relative to the current front);
/// `prefix` has `logCount + 1` entries with `prefix[0] == 0` and `prefix.last ==`
/// `totalRows`. Appends are O(1); front-trims rebase the remainder (O(remaining),
/// matching the list's existing per-trim cost and rare — only past the ring cap).
struct DisplayLineMap: Equatable {
    private var prefix: [Int] = [0]

    /// Total display rows across every retained log.
    var totalRows: Int { prefix[prefix.count - 1] }
    /// Number of log entries mapped.
    var logCount: Int { prefix.count - 1 }
    var isEmpty: Bool { logCount == 0 }

    /// Appends a log occupying `lineCount` rows (clamped to ≥ 1).
    mutating func append(lineCount: Int) {
        prefix.append(prefix[prefix.count - 1] + max(1, lineCount))
    }

    mutating func removeAll() { prefix = [0] }

    /// Prepends logs (oldest-first `lineCounts`) at the front, shifting existing offsets up.
    /// Returns the number of display rows added — used to compensate the viewport scroll when
    /// older entries load *above* what the user is looking at.
    @discardableResult
    mutating func prepend<C: Collection>(lineCounts: C) -> Int where C.Element == Int {
        guard !lineCounts.isEmpty else { return 0 }
        var head = [0]
        head.reserveCapacity(lineCounts.count + prefix.count)
        var running = 0
        for c in lineCounts { running += max(1, c); head.append(running) }
        let addedRows = running
        head.removeLast()                                   // its trailing total == shifted prefix[0]
        for offset in prefix { head.append(offset + addedRows) }
        prefix = head
        return addedRows
    }

    /// Drops the first `k` logs and rebases the remaining offsets to start at 0.
    /// Returns the number of display rows removed (to compensate the viewport scroll).
    @discardableResult
    mutating func removeFirst(_ k: Int) -> Int {
        guard k > 0 else { return 0 }
        let k = min(k, logCount)
        let removedRows = prefix[k]
        prefix.removeFirst(k)
        if removedRows != 0 {
            for i in prefix.indices { prefix[i] -= removedRows }
        }
        return removedRows
    }

    /// Rebuilds the map from a sequence of per-log row counts (used when the visible
    /// slice is recomputed wholesale, e.g. a filter change).
    mutating func rebuild<S: Sequence>(lineCounts: S) where S.Element == Int {
        var p = [0]
        p.reserveCapacity(prefix.capacity)
        var running = 0
        for c in lineCounts { running += max(1, c); p.append(running) }
        prefix = p
    }

    /// The `(logIndex, subLine)` a display row belongs to. Binary search; O(log n).
    /// Returns `(0, 0)` when empty (callers gate on `row < totalRows`).
    func locate(row: Int) -> (log: Int, sub: Int) {
        guard logCount > 0 else { return (0, 0) }
        var lo = 0, hi = logCount - 1, ans = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if prefix[mid] <= row { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return (ans, row - prefix[ans])
    }

    /// First display row of log `i`.
    func firstRow(ofLog i: Int) -> Int { prefix[i] }

    /// The contiguous display-row range occupied by log `i`.
    func rows(ofLog i: Int) -> ClosedRange<Int> { prefix[i]...(prefix[i + 1] - 1) }
}
