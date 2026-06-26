import AppKit
import SwiftUI
import Lemonade

/// Virtualized Cloud Logging list backed by `NSTableView` — a focused clone of `LogTableView`
/// so a streaming cloud session gets the same flat-cost scrolling, follow-tail, and front-trim
/// behavior (req 10). Columns: time · severity badge · log id · message. Selecting a row opens
/// the detail panel (`session.selectedEntry`). Multi-line messages (pretty json/proto payloads)
/// span several display rows via `DisplayLineMap`, exactly like the device log list.
struct CloudLogTableView: NSViewRepresentable {
    let session: CloudLogSession
    var isActive: Bool
    var revision: Int        // session.visible.count
    var epoch: Int           // session.listEpoch
    var follow: Bool         // session.followTail
    var selectedSeq: UInt64? // session.selectedEntry?.seq

    static let rowHeight: CGFloat = 18

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = CloudLogNSTableView()
        table.session = session
        table.rowHeight = Self.rowHeight
        table.headerView = nil
        table.backgroundColor = NSColor(LemonadeTheme.colors.background.bgDefault)
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        table.usesAlternatingRowBackgroundColors = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        let col = NSTableColumn(identifier: .init("cloud"))
        col.minWidth = 200
        col.resizingMask = []
        table.addTableColumn(col)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(LemonadeTheme.colors.background.bgDefault)
        scroll.automaticallyAdjustsContentInsets = false

        context.coordinator.table = table
        context.coordinator.scroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak coord = context.coordinator] _ in
            MainActor.assumeIsolated { coord?.userScrolled() }
        }
        scroll.contentView.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak coord = context.coordinator] _ in
            MainActor.assumeIsolated { coord?.applyColumnWidth() }
        }

        context.coordinator.reloadAll()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let c = context.coordinator
        c.session = session
        c.isActive = isActive
        (nsView.documentView as? CloudLogNSTableView)?.session = session
        c.apply(epoch: epoch, following: follow)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if let o = coordinator.boundsObserver { NotificationCenter.default.removeObserver(o) }
        if let o = coordinator.frameObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var session: CloudLogSession
        weak var table: CloudLogNSTableView?
        weak var scroll: NSScrollView?
        var isActive = true
        var boundsObserver: Any?
        var frameObserver: Any?

        private var lastCount = 0
        private var lastEpoch = -1
        private var lastDropped = 0
        private var programmaticScroll = false
        private var widestContent: CGFloat = 0
        private var syncingSelection = false

        init(session: CloudLogSession) { self.session = session }

        func numberOfRows(in tableView: NSTableView) -> Int { session.displayRowCount }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("cloudRow")
            if let rv = tableView.makeView(withIdentifier: id, owner: self) as? CloudSelectionRowView { return rv }
            let rv = CloudSelectionRowView(); rv.identifier = id; return rv
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("cloudCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? CloudCellNSView)
                ?? { let v = CloudCellNSView(); v.identifier = id; return v }()
            if row < session.displayRowCount {
                let loc = session.locate(displayRow: row)
                let entry = session.visible[loc.log]
                cell.configure(entry: entry, displayText: session.displayMessage(entry), subLine: loc.sub)
                growColumn(forContentWidth: LogRowLayout.messageX + cell.messageLineWidth + LogRowLayout.pad)
            } else {
                cell.configure(entry: nil, displayText: "", subLine: 0)
            }
            return cell
        }

        func growColumn(forContentWidth w: CGFloat) {
            guard w > widestContent else { return }
            widestContent = w
            DispatchQueue.main.async { [weak self] in self?.applyColumnWidth() }
        }

        func applyColumnWidth() {
            guard let table, let col = table.tableColumns.first, let scroll else { return }
            let target = max(scroll.contentView.bounds.width, widestContent)
            if abs(col.width - target) > 0.5 { col.width = target }
        }

        /// Clicking any sub-line selects the whole (possibly multi-line) entry.
        func tableView(_ tableView: NSTableView,
                       selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
            var expanded = IndexSet()
            for r in proposed where r < session.displayRowCount {
                expanded.insert(integersIn: session.displayRowRange(ofLog: session.locate(displayRow: r).log))
            }
            return expanded
        }

        /// Drive the detail panel from the table selection.
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncingSelection, let table else { return }
            let row = table.selectedRow
            guard row >= 0, row < session.displayRowCount else { return }
            let logIndex = session.locate(displayRow: row).log
            if logIndex < session.visible.count {
                let entry = session.visible[logIndex]
                if !entry.isSynthetic { session.selectedEntry = entry }   // dividers aren't inspectable
            }
        }

        func apply(epoch: Int, following: Bool) {
            guard let table else { return }
            let count = session.displayRowCount
            let dropped = session.droppedDisplayRows

            if epoch != lastEpoch {
                widestContent = 0
                applyColumnWidth()
                table.reloadData()
            } else {
                let frontTrim = dropped - lastDropped
                if frontTrim > 0 {
                    keepViewportThroughTrim(frontTrim, following: following)
                } else if count != lastCount {
                    table.noteNumberOfRowsChanged()
                }
            }
            lastCount = count; lastDropped = dropped; lastEpoch = epoch

            if following { scrollToBottom() }
        }

        private func keepViewportThroughTrim(_ frontTrim: Int, following: Bool) {
            guard let table else { return }
            table.reloadData()
            if !following, let scroll {
                var o = scroll.contentView.bounds.origin
                o.y = max(0, o.y - CGFloat(frontTrim) * CloudLogTableView.rowHeight)
                programmaticScroll = true
                scroll.contentView.scroll(to: o)
                scroll.reflectScrolledClipView(scroll.contentView)
                programmaticScroll = false
            }
        }

        func reloadAll() {
            table?.reloadData()
            lastCount = session.displayRowCount
            lastEpoch = session.listEpoch
            lastDropped = session.droppedDisplayRows
            if session.followTail { scrollToBottom() }
        }

        func scrollToBottom() {
            guard let table, session.displayRowCount > 0 else { return }
            programmaticScroll = true
            table.scrollRowToVisible(session.displayRowCount - 1)
            DispatchQueue.main.async { [weak self] in self?.programmaticScroll = false }
        }

        func userScrolled() {
            guard isActive, !programmaticScroll, let scroll, let table else { return }
            let atBottom = scroll.contentView.bounds.maxY >= table.bounds.height - CloudLogTableView.rowHeight * 0.5
            if atBottom {
                if !session.followTail { session.followTail = true }
            } else if session.followTail {
                session.followTail = false
            }
        }
    }
}

// MARK: - AppKit table (copy / context menu)

final class CloudLogNSTableView: NSTableView {
    weak var session: CloudLogSession?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            copyRows(); return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { copyRows() }

    func copyRows() {
        guard let session else { return }
        let entries = session.logIndices(forDisplayRows: selectedRowIndexes)
            .compactMap { $0 < session.visible.count ? session.visible[$0] : nil }
        guard !entries.isEmpty else { return }
        let text = entries.map { entry -> String in
            let time = entry.timestamp.logClock
            let tag = entry.tag.isEmpty ? "" : " \(entry.tag)"
            return "\(time) \(entry.severity.apiName)\(tag)  \(entry.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let session else { return nil }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, row < session.displayRowCount, !selectedRowIndexes.contains(row) {
            let range = session.displayRowRange(ofLog: session.locate(displayRow: row).log)
            selectRowIndexes(IndexSet(integersIn: range), byExtendingSelection: false)
        }
        guard !selectedRowIndexes.isEmpty else { return nil }
        let n = session.logIndices(forDisplayRows: selectedRowIndexes).count
        let menu = NSMenu()
        menu.addItem(withTitle: n > 1 ? "Copy \(n) Entries" : "Copy Entry",
                     action: #selector(copyMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.items.forEach { if $0.action != #selector(selectAll(_:)) { $0.target = self } }
        return menu
    }

    @objc private func copyMenu() { copyRows() }
}

// MARK: - Selection row view

final class CloudSelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor(LemonadeTheme.colors.interaction.bgSubtleInteractive).setFill()
        bounds.fill()
    }
    override var isEmphasized: Bool { get { false } set {} }
}

// MARK: - Row content drawing

/// Draws one display row of a cloud entry. Sub-line 0 carries time / severity badge / log id;
/// continuation rows draw only their message text (aligned under the message column).
final class CloudCellNSView: NSView {
    private(set) var entry: CloudLogEntry?
    private var subLine = 0
    private var displayLines: [String] = [""]
    private var truncated = false
    private var cachedMessage: String?
    private(set) var messageLineWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    func configure(entry: CloudLogEntry?, displayText: String, subLine: Int) {
        if displayText != cachedMessage {
            cachedMessage = displayText
            displayLines = LogTextLines.displayLines(displayText)
            truncated = LogTextLines.isTruncated(displayText)
        }
        self.entry = entry
        self.subLine = subLine
        let text = subLine < displayLines.count ? displayLines[subLine] : ""
        messageLineWidth = (text as NSString).size(withAttributes: LogColors.attr(LogColors.timestamp)).width
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let entry else { return }
        let h = bounds.height
        let ty = (h - LogColors.lineHeight) / 2

        // A SQL-injected divider/marker row: centered, dim, no time / badge / log id.
        if entry.isSynthetic {
            guard subLine < displayLines.count else { return }
            let text = displayLines[subLine] as NSString
            let attrs = LogColors.attr(LogColors.timestamp)
            let size = text.size(withAttributes: attrs)
            let x = max(LogRowLayout.pad, (bounds.width - size.width) / 2)
            text.draw(at: NSPoint(x: x, y: ty), withAttributes: attrs)
            return
        }

        if subLine == 0 {
            var x = LogRowLayout.pad
            entry.timestamp.logClock.draw(
                in: NSRect(x: x, y: ty, width: LogRowLayout.timeW, height: LogColors.lineHeight),
                withAttributes: LogColors.attr(LogColors.timestamp))
            x += LogRowLayout.timeW + LogRowLayout.gap

            let badge = NSRect(x: x, y: (h - 14) / 2, width: LogRowLayout.badgeW, height: 14)
            CloudLogColors.badgeBG(entry.severity).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            let glyph = entry.severity.short
            let glyphAttrs = LogColors.attrBold(CloudLogColors.color(entry.severity))
            let glyphSize = (glyph as NSString).size(withAttributes: glyphAttrs)
            glyph.draw(at: NSPoint(x: badge.midX - glyphSize.width / 2, y: ty), withAttributes: glyphAttrs)
            x += LogRowLayout.badgeW + LogRowLayout.gap

            if !entry.tag.isEmpty {
                (entry.tag as NSString).draw(
                    in: NSRect(x: x, y: ty, width: LogRowLayout.tagW, height: LogColors.lineHeight),
                    withAttributes: LogColors.attrTruncating(LogColors.tag))
            }
        }

        guard subLine < displayLines.count else { return }
        let isIndicator = truncated && subLine == displayLines.count - 1
        let color = isIndicator ? LogColors.timestamp : CloudLogColors.color(entry.severity)
        (displayLines[subLine] as NSString).draw(at: NSPoint(x: LogRowLayout.messageX, y: ty),
                                                 withAttributes: LogColors.attr(color))
    }
}

/// Cached AppKit colors for cloud severities (the `LogColors` analogue; CloudSeverity's raw
/// values aren't contiguous, so we memoize per case instead of an array).
enum CloudLogColors {
    private static var colorCache: [CloudSeverity: NSColor] = [:]
    private static var badgeCache: [CloudSeverity: NSColor] = [:]

    static func color(_ severity: CloudSeverity) -> NSColor {
        if let c = colorCache[severity] { return c }
        let c = NSColor(CloudSeverityStyle.color(for: severity))
        colorCache[severity] = c
        return c
    }

    static func badgeBG(_ severity: CloudSeverity) -> NSColor {
        if let c = badgeCache[severity] { return c }
        let c = NSColor(CloudSeverityStyle.badgeBackground(for: severity))
        badgeCache[severity] = c
        return c
    }
}
