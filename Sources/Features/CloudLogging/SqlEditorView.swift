import SwiftUI
import AppKit
import Lemonade

/// A small code editor for the SQL mode: an `NSTextView` with SQL **syntax highlighting** and
/// **autocomplete** of keywords + the known `log_entry` columns (the schema is fixed, so we can
/// complete it exactly). ⌘↩ runs the query. The parent can insert text at the cursor (the label
/// helper uses it) via `insertHook`.
struct SqlEditorView: NSViewRepresentable {
    @Binding var text: String
    var onRun: () -> Void = {}
    /// Set by the editor to a closure that inserts text at the cursor (for the label helper).
    var insertHook: Binding<((String) -> Void)?>?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SqlTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = Self.font
        textView.textColor = NSColor(LemonadeTheme.colors.content.contentPrimary)
        textView.insertionPointColor = NSColor(LemonadeTheme.colors.content.contentPrimary)
        textView.backgroundColor = NSColor(LemonadeTheme.colors.background.bgNeutralSubtle)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = text
        textView.onRun = onRun

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        context.coordinator.textView = textView
        context.coordinator.highlight()
        let hook = insertHook
        DispatchQueue.main.async { hook?.wrappedValue = { [weak textView] s in textView?.insertAtCursor(s) } }

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(LemonadeTheme.colors.background.bgNeutralSubtle)
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.onRun = onRun
        if textView.string != text {   // external change (template / "from current filter")
            let length = (text as NSString).length
            let caret = min(textView.selectedRange().location, length)
            textView.string = text
            context.coordinator.highlight()
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        }
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: SqlEditorView
        weak var textView: SqlTextView?
        init(_ parent: SqlEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            highlight()
        }

        func highlight() {
            guard let storage = textView?.textStorage else { return }
            SqlHighlighter.apply(to: storage, font: SqlEditorView.font)
        }

        func textView(_ textView: NSTextView, completions words: [String],
                      forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let partial = (textView.string as NSString).substring(with: charRange).lowercased()
            guard !partial.isEmpty else { return [] }
            let candidates = CloudSqlSchema.columnNames + CloudSqlSchema.keywords
            let matches = candidates.filter { $0.lowercased().hasPrefix(partial) && $0.lowercased() != partial }
            return Array(Set(matches)).sorted { $0.lowercased() < $1.lowercased() }
        }
    }
}

/// NSTextView that auto-triggers completion as you type an identifier, runs on ⌘↩, and can
/// insert text at the cursor.
final class SqlTextView: NSTextView {
    var onRun: () -> Void = {}

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard let s = string as? String, let ch = s.last, ch.isLetter || ch == "_" else { return }
        if rangeForUserCompletion.length >= 2 { complete(nil) }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 36 {   // ⌘ + Return
            onRun(); return
        }
        super.keyDown(with: event)
    }

    func insertAtCursor(_ s: String) {
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: s) else { return }
        textStorage?.replaceCharacters(in: range, with: s)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (s as NSString).length, length: 0))
    }
}

/// Single-pass SQL tokenizer that colors keywords, columns, strings, comments and numbers.
/// Re-applied on each edit (the SQL is short).
enum SqlHighlighter {
    private static let keyword = NSColor(LemonadeTheme.colors.content.contentBrand)
    private static let column = NSColor(calibratedRed: 0.20, green: 0.60, blue: 0.62, alpha: 1)
    private static let string = NSColor(calibratedRed: 0.30, green: 0.62, blue: 0.36, alpha: 1)
    private static let comment = NSColor(LemonadeTheme.colors.content.contentTertiary)
    private static let number = NSColor(calibratedRed: 0.83, green: 0.50, blue: 0.20, alpha: 1)
    private static let normal = NSColor(LemonadeTheme.colors.content.contentPrimary)
    private static let columnSet = Set(CloudSqlSchema.columnNames)

    static func apply(to storage: NSTextStorage, font: NSFont) {
        let ns = storage.string as NSString
        let length = ns.length
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: normal], range: NSRange(location: 0, length: length))

        func isIdentStart(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        func isIdent(_ c: unichar) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }

        var i = 0
        while i < length {
            let c = ns.character(at: i)
            if c == 45, i + 1 < length, ns.character(at: i + 1) == 45 {           // -- comment
                var j = i
                while j < length, ns.character(at: j) != 10 { j += 1 }
                storage.addAttribute(.foregroundColor, value: comment, range: NSRange(location: i, length: j - i))
                i = j
            } else if c == 39 {                                                   // 'string'
                var j = i + 1
                while j < length {
                    if ns.character(at: j) == 39 {
                        if j + 1 < length, ns.character(at: j + 1) == 39 { j += 2; continue }
                        j += 1; break
                    }
                    j += 1
                }
                let end = min(j, length)
                storage.addAttribute(.foregroundColor, value: string, range: NSRange(location: i, length: end - i))
                i = end
            } else if c >= 48 && c <= 57 {                                        // number
                var j = i
                while j < length, (ns.character(at: j) >= 48 && ns.character(at: j) <= 57) || ns.character(at: j) == 46 { j += 1 }
                storage.addAttribute(.foregroundColor, value: number, range: NSRange(location: i, length: j - i))
                i = j
            } else if isIdentStart(c) {                                           // ident / keyword / column
                var j = i
                while j < length, isIdent(ns.character(at: j)) { j += 1 }
                let word = ns.substring(with: NSRange(location: i, length: j - i))
                if CloudSqlSchema.keywordSet.contains(word.uppercased()) {
                    storage.addAttribute(.foregroundColor, value: keyword, range: NSRange(location: i, length: j - i))
                } else if columnSet.contains(word.lowercased()) {
                    storage.addAttribute(.foregroundColor, value: column, range: NSRange(location: i, length: j - i))
                }
                i = j
            } else {
                i += 1
            }
        }
        storage.endEditing()
    }
}
