import AppKit
import SwiftUI
import Lemonade

/// Virtualized log list backed by `NSTableView` — the Cocoa equivalent of Zed's
/// `uniform_list`: a fixed row height means only the visible rows are ever built
/// (and they're recycled), so scrolling a 500k-line buffer costs the same as a tiny
/// one. Appends never move the viewport (`noteNumberOfRowsChanged()`); follow-tail
/// pins to the bottom and disengages when you scroll up; a front-trim compensates the
/// scroll so your position stays put (the `list.rs` anchor trick). Selection, ⌘C,
/// drag-select and the context menu are native AppKit.
struct LogTableView: NSViewRepresentable {
    let session: LogSession
    var isActive: Bool
    // Stored purely so SwiftUI re-runs updateNSView when the session mutates — the
    // parent reads these in its body, which is what creates the @Observable
    // dependency that drives the re-render.
    var revision: Int        // session.visible.count
    var epoch: Int           // session.listEpoch (wholesale changes)
    var follow: Bool         // session.followTail
    var target: UInt64?      // session.scrollTarget

    static let rowHeight: CGFloat = 18

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = LogNSTableView()
        table.session = session
        table.rowHeight = Self.rowHeight
        table.headerView = nil
        table.backgroundColor = NSColor(LemonadeTheme.colors.background.bgDefault)
        table.selectionHighlightStyle = .regular   // we recolor it in the row view
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        table.usesAlternatingRowBackgroundColors = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        // We size the single column ourselves (to the widest line seen) so an over-long
        // line becomes horizontally scrollable instead of clipped — auto-resizing would
        // pin it to the viewport width and there'd be nothing to scroll.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        let col = NSTableColumn(identifier: .init("log"))
        col.minWidth = 200
        col.resizingMask = []
        table.addTableColumn(col)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true        // appears only when a line overflows
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
        // Keep the column at least viewport-wide as the window resizes.
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
        (nsView.documentView as? LogNSTableView)?.session = session
        c.apply(epoch: epoch, target: target, following: follow)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if let o = coordinator.boundsObserver { NotificationCenter.default.removeObserver(o) }
        if let o = coordinator.frameObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var session: LogSession
        weak var table: LogNSTableView?
        weak var scroll: NSScrollView?
        var isActive = true
        var boundsObserver: Any?
        var frameObserver: Any?

        private var lastCount = 0
        private var lastEpoch = -1
        private var lastDropped = 0
        private var programmaticScroll = false
        /// Widest rendered row (including the metadata columns) seen so far — the column
        /// grows to this so the widest line is fully reachable by horizontal scroll.
        private var widestContent: CGFloat = 0

        init(session: LogSession) { self.session = session }

        // MARK: data

        // One table row per *display* line — a log with embedded newlines spans several.
        func numberOfRows(in tableView: NSTableView) -> Int { session.displayRowCount }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("logRow")
            if let rv = tableView.makeView(withIdentifier: id, owner: self) as? LogSelectionRowView { return rv }
            let rv = LogSelectionRowView(); rv.identifier = id; return rv
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("logCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? LogCellNSView)
                ?? { let v = LogCellNSView(); v.identifier = id; return v }()
            if row < session.displayRowCount {
                let loc = session.locate(displayRow: row)
                cell.configure(line: session.visible[loc.log], subLine: loc.sub)
                growColumn(forContentWidth: LogRowLayout.messageX + cell.messageLineWidth + LogRowLayout.pad)
            } else {
                cell.configure(line: nil, subLine: 0)
            }
            return cell
        }

        /// Grows the column so a newly-seen wide line is fully reachable. The column
        /// never shrinks below the viewport (so it always fills the width) and only
        /// shrinks back when the list is cleared/refiltered. Deferred so we never mutate
        /// the column width while the table is mid-vending its row views.
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

        /// Clicking/dragging any sub-line selects the whole log it belongs to, so a
        /// multi-line entry highlights as one block and copies as one entry.
        func tableView(_ tableView: NSTableView,
                       selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
            var expanded = IndexSet()
            for r in proposed where r < session.displayRowCount {
                expanded.insert(integersIn: session.displayRowRange(ofLog: session.locate(displayRow: r).log))
            }
            return expanded
        }

        // MARK: updates

        /// Decides the cheapest table operation for what changed, then applies follow /
        /// scroll-to-target.
        func apply(epoch: Int, target: UInt64?, following: Bool) {
            guard let table else { return }
            // Work in display-row units: multi-line logs make rows ≠ logs, but rows stay
            // uniform-height, so the trim/append math below is unchanged in shape.
            let count = session.displayRowCount
            let dropped = session.droppedDisplayRows

            if epoch != lastEpoch {
                widestContent = 0                        // new content → re-measure widths
                applyColumnWidth()
                table.reloadData()                       // wholesale change (clear/filter)
            } else {
                let frontTrim = dropped - lastDropped
                if frontTrim > 0 {
                    keepViewportThroughTrim(frontTrim, following: following)
                } else if count != lastCount {
                    table.noteNumberOfRowsChanged()      // append-only: rows above untouched
                }
            }
            lastCount = count; lastDropped = dropped; lastEpoch = epoch

            if following { scrollToBottom() }
            if let target {
                scrollToSeq(target)
                DispatchQueue.main.async { [weak self] in self?.session.scrollTarget = nil }
            }
        }

        /// The ring trimmed the oldest lines. Reload, and if the user is reading
        /// (not following) shift the scroll up by the trimmed height so the lines on
        /// screen don't move — Zed's logical-anchor-survives-splice behaviour.
        private func keepViewportThroughTrim(_ frontTrim: Int, following: Bool) {
            guard let table else { return }
            let selected = table.selectedRowIndexes
            table.reloadData()
            if !following, let scroll {
                var o = scroll.contentView.bounds.origin
                o.y = max(0, o.y - CGFloat(frontTrim) * LogTableView.rowHeight)
                programmaticScroll = true
                scroll.contentView.scroll(to: o)
                scroll.reflectScrolledClipView(scroll.contentView)
                programmaticScroll = false
            }
            if !selected.isEmpty {
                let shifted = IndexSet(selected.compactMap { $0 >= frontTrim ? $0 - frontTrim : nil })
                table.selectRowIndexes(shifted, byExtendingSelection: false)
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

        func scrollToSeq(_ seq: UInt64) {
            guard let table, let logIdx = session.logIndex(forSeq: seq) else { return }
            let idx = session.firstDisplayRow(ofLog: logIdx)
            programmaticScroll = true
            // Center it: scroll the row, then nudge so it sits mid-viewport.
            table.scrollRowToVisible(idx)
            if let scroll {
                let rowY = CGFloat(idx) * LogTableView.rowHeight
                let target = max(0, rowY - scroll.contentView.bounds.height / 2)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            DispatchQueue.main.async { [weak self] in self?.programmaticScroll = false }
        }

        /// User scrolled: engage follow when we're back at the bottom, disengage when
        /// they move away. Guarded against our own programmatic scrolls.
        func userScrolled() {
            guard isActive, !programmaticScroll, let scroll, let table else { return }
            // Marker dividers are centred on the viewport, so re-draw them when the
            // visible rect shifts (notably a horizontal scroll of a long line).
            table.enumerateAvailableRowViews { rowView, _ in
                for sub in rowView.subviews where (sub as? LogCellNSView)?.isMarkerRow == true {
                    sub.needsDisplay = true
                }
            }
            let atBottom = scroll.contentView.bounds.maxY >= table.bounds.height - LogTableView.rowHeight * 0.5
            if atBottom {
                if !session.followTail { session.followTail = true }
            } else if session.followTail {
                session.followTail = false
            }
        }
    }
}

// MARK: - AppKit table (copy / context menu)

final class LogNSTableView: NSTableView {
    weak var session: LogSession?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            copyRows(messagesOnly: true); return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { copyRows(messagesOnly: true) }   // Edit ▸ Copy

    func copyRows(messagesOnly: Bool) {
        guard let session else { return }
        let lines = session.logIndices(forDisplayRows: selectedRowIndexes)
            .compactMap { $0 < session.visible.count ? session.visible[$0] : nil }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(LogClipboard.text(for: lines, messagesOnly: messagesOnly), forType: .string)
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
        menu.addItem(withTitle: n > 1 ? "Copy \(n) Messages" : "Copy Message",
                     action: #selector(copyMessages), keyEquivalent: "")
        menu.addItem(withTitle: n > 1 ? "Copy \(n) Lines (with time & tag)" : "Copy Line",
                     action: #selector(copyLinesFull), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.items.forEach { if $0.action != #selector(selectAll(_:)) { $0.target = self } }
        return menu
    }

    @objc private func copyMessages() { copyRows(messagesOnly: true) }
    @objc private func copyLinesFull() { copyRows(messagesOnly: false) }
}

// MARK: - Selection row view (recoloured highlight)

final class LogSelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        LogColors.selection.setFill()
        bounds.fill()
    }
    override var isEmphasized: Bool { get { false } set {} }   // no blue system tint
}

// MARK: - Row geometry (shared by drawing + horizontal-scroll measuring)

enum LogRowLayout {
    static let pad: CGFloat = 12
    static let gap: CGFloat = 8
    static let timeW: CGFloat = 92
    static let badgeW: CGFloat = 16
    static let tagW: CGFloat = 168
    /// x where the message column starts (after timestamp + level badge + tag).
    static let messageX: CGFloat = pad + timeW + gap + badgeW + gap + tagW + gap
}

// MARK: - Row content drawing

/// Draws one **display row**: a single line of a (possibly multi-line) log entry.
/// Sub-line 0 carries the timestamp/level/tag; continuation rows draw only their
/// text, aligned under the message column. The message is drawn at its full natural
/// width — an over-long line stays reachable via the horizontal scroller (the column
/// grows to the widest line) rather than being truncated with a "…".
final class LogCellNSView: NSView {
    private(set) var line: LogLine?
    private var subLine = 0
    private var displayLines: [String] = [""]
    private var truncated = false
    private var cachedMessage: String?
    /// True when this row renders a synthetic marker (centred on the viewport).
    private(set) var isMarkerRow = false
    /// Width of this row's message text, used by the table to size the column so the
    /// widest line is fully reachable by horizontal scroll.
    private(set) var messageLineWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    func configure(line: LogLine?, subLine: Int) {
        if line?.message != cachedMessage {
            cachedMessage = line?.message
            if let message = line?.message {
                displayLines = LogTextLines.displayLines(message)
                truncated = LogTextLines.isTruncated(message)
            } else {
                displayLines = [""]
                truncated = false
            }
        }
        self.line = line
        self.subLine = subLine
        self.isMarkerRow = line?.isMarker ?? false
        let text = subLine < displayLines.count ? displayLines[subLine] : ""
        messageLineWidth = (text as NSString).size(withAttributes: LogColors.attr(LogColors.timestamp)).width
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let line else { return }
        if line.isMarker {
            if subLine == 0 { drawMarker(line) }
        } else {
            drawLog(line, sub: subLine)
        }
    }

    private func drawLog(_ line: LogLine, sub: Int) {
        let h = bounds.height
        let ty = (h - LogColors.lineHeight) / 2

        // Metadata columns only on the first line; continuation lines are message-only.
        if sub == 0 {
            var x = LogRowLayout.pad
            line.timestamp.logClock.draw(
                in: NSRect(x: x, y: ty, width: LogRowLayout.timeW, height: LogColors.lineHeight),
                withAttributes: LogColors.attr(LogColors.timestamp))
            x += LogRowLayout.timeW + LogRowLayout.gap

            let badge = NSRect(x: x, y: (h - 14) / 2, width: LogRowLayout.badgeW, height: 14)
            LogColors.badgeBG[line.level.rawValue].setFill()
            NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            let lvl = line.level.short
            let lvlAttrs = LogColors.attrBold(LogColors.level[line.level.rawValue])
            let lvlSize = (lvl as NSString).size(withAttributes: lvlAttrs)
            lvl.draw(at: NSPoint(x: badge.midX - lvlSize.width / 2, y: ty), withAttributes: lvlAttrs)
            x += LogRowLayout.badgeW + LogRowLayout.gap

            if !line.tag.isEmpty {
                tagLabel(line).draw(in: NSRect(x: x, y: ty, width: LogRowLayout.tagW, height: LogColors.lineHeight),
                                    withAttributes: LogColors.attrTruncating(LogColors.tag))
            }
        }

        // message line — drawn at its natural width; an over-long line is reached via the
        // horizontal scroller (the column grows to fit the widest line).
        guard sub < displayLines.count else { return }
        let isIndicator = truncated && sub == displayLines.count - 1
        let color = isIndicator ? LogColors.timestamp : LogColors.level[line.level.rawValue]
        (displayLines[sub] as NSString).draw(at: NSPoint(x: LogRowLayout.messageX, y: ty),
                                             withAttributes: LogColors.attr(color))
    }

    private func tagLabel(_ line: LogLine) -> String {
        line.pid > 0 ? "\(line.tag) (\(line.pid))" : line.tag
    }

    private func drawMarker(_ line: LogLine) {
        let color = line.markerCritical ? LogColors.markerCritical : LogColors.marker
        let h = bounds.height
        let attrs = LogColors.attrBold(color)
        let size = (line.message as NSString).size(withAttributes: attrs)
        // Centre on the *visible* viewport, not the (possibly very wide) column, so the
        // divider stays put while a long line is scrolled horizontally.
        let vis = enclosingScrollView?.documentVisibleRect ?? bounds
        let originX = vis.minX, visW = vis.width
        let tx = originX + (visW - size.width) / 2
        let ty = (h - LogColors.lineHeight) / 2
        line.message.draw(at: NSPoint(x: tx, y: ty), withAttributes: attrs)
        // rules either side of the centred label
        color.withAlphaComponent(0.45).setFill()
        let ruleY = h / 2
        NSRect(x: originX + 12, y: ruleY, width: max(0, tx - (originX + 12) - 10), height: 1).fill()
        NSRect(x: tx + size.width + 10, y: ruleY,
               width: max(0, (originX + visW) - (tx + size.width) - 10 - 12), height: 1).fill()
    }
}

// MARK: - Cached AppKit colors / text attributes

enum LogColors {
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let fontBold = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    static let lineHeight: CGFloat = NSLayoutManager().defaultLineHeight(for: font)

    static let timestamp = NSColor(LemonadeTheme.colors.content.contentTertiary)
    static let tag = NSColor(LemonadeTheme.colors.content.contentSecondary)
    static let selection = NSColor(LemonadeTheme.colors.interaction.bgSubtleInteractive)
    static let marker = NSColor(red: 0.62, green: 0.45, blue: 1.0, alpha: 1)
    static let markerCritical = NSColor(LemonadeTheme.colors.content.contentCritical)

    static let level: [NSColor] = LogLevel.allCases.map { NSColor(LogLevelStyle.color(for: $0)) }
    static let badgeBG: [NSColor] = LogLevel.allCases.map { NSColor(LogLevelStyle.badgeBackground(for: $0)) }

    private static let truncating: NSParagraphStyle = {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; return p
    }()

    static func attr(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }
    static func attrBold(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: fontBold, .foregroundColor: color]
    }
    static func attrTruncating(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .paragraphStyle: truncating]
    }
}
