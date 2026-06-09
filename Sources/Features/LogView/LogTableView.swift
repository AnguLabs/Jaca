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
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let col = NSTableColumn(identifier: .init("log"))
        col.minWidth = 200
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
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
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var session: LogSession
        weak var table: LogNSTableView?
        weak var scroll: NSScrollView?
        var isActive = true
        var boundsObserver: Any?

        private var lastCount = 0
        private var lastEpoch = -1
        private var lastDropped = 0
        private var programmaticScroll = false

        init(session: LogSession) { self.session = session }

        // MARK: data

        func numberOfRows(in tableView: NSTableView) -> Int { session.visible.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("logRow")
            if let rv = tableView.makeView(withIdentifier: id, owner: self) as? LogSelectionRowView { return rv }
            let rv = LogSelectionRowView(); rv.identifier = id; return rv
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("logCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? LogCellNSView)
                ?? { let v = LogCellNSView(); v.identifier = id; return v }()
            cell.line = row < session.visible.count ? session.visible[row] : nil
            return cell
        }

        // MARK: updates

        /// Decides the cheapest table operation for what changed, then applies follow /
        /// scroll-to-target.
        func apply(epoch: Int, target: UInt64?, following: Bool) {
            guard let table else { return }
            let count = session.visible.count
            let dropped = session.droppedCount

            if epoch != lastEpoch {
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
            lastCount = session.visible.count
            lastEpoch = session.listEpoch
            lastDropped = session.droppedCount
            if session.followTail { scrollToBottom() }
        }

        func scrollToBottom() {
            guard let table, !session.visible.isEmpty else { return }
            programmaticScroll = true
            table.scrollRowToVisible(session.visible.count - 1)
            DispatchQueue.main.async { [weak self] in self?.programmaticScroll = false }
        }

        func scrollToSeq(_ seq: UInt64) {
            guard let table, let idx = session.visible.firstIndex(where: { $0.seq == seq }) else { return }
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
        let lines = selectedRowIndexes.compactMap { $0 < session.visible.count ? session.visible[$0] : nil }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(LogClipboard.text(for: lines, messagesOnly: messagesOnly), forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        guard !selectedRowIndexes.isEmpty else { return nil }
        let n = selectedRowIndexes.count
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

// MARK: - Row content drawing

final class LogCellNSView: NSView {
    var line: LogLine? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let line else { return }
        if line.isMarker { drawMarker(line) } else { drawLog(line) }
    }

    private func drawLog(_ line: LogLine) {
        let h = bounds.height, w = bounds.width
        let ty = (h - LogColors.lineHeight) / 2
        let pad: CGFloat = 12, gap: CGFloat = 8
        let timeW: CGFloat = 92, badgeW: CGFloat = 16, tagW: CGFloat = 168

        var x = pad
        line.timestamp.logClock.draw(in: NSRect(x: x, y: ty, width: timeW, height: LogColors.lineHeight),
                                     withAttributes: LogColors.attr(LogColors.timestamp))
        x += timeW + gap

        // level badge
        let badge = NSRect(x: x, y: (h - 14) / 2, width: badgeW, height: 14)
        let path = NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3)
        LogColors.badgeBG[line.level.rawValue].setFill(); path.fill()
        let lvl = line.level.short
        let lvlSize = (lvl as NSString).size(withAttributes: LogColors.attrBold(LogColors.level[line.level.rawValue]))
        lvl.draw(at: NSPoint(x: badge.midX - lvlSize.width / 2, y: ty),
                 withAttributes: LogColors.attrBold(LogColors.level[line.level.rawValue]))
        x += badgeW + gap

        // tag (reserved width, truncated) — keeps the message column aligned
        if !line.tag.isEmpty {
            tagLabel(line).draw(in: NSRect(x: x, y: ty, width: tagW, height: LogColors.lineHeight),
                                withAttributes: LogColors.attrTruncating(LogColors.tag))
        }
        x += tagW + gap

        // message (one line, truncated)
        let msgW = max(0, w - x - pad)
        line.message.draw(in: NSRect(x: x, y: ty, width: msgW, height: LogColors.lineHeight),
                          withAttributes: LogColors.attrTruncating(LogColors.level[line.level.rawValue]))
    }

    private func tagLabel(_ line: LogLine) -> String {
        line.pid > 0 ? "\(line.tag) (\(line.pid))" : line.tag
    }

    private func drawMarker(_ line: LogLine) {
        let color = line.markerCritical ? LogColors.markerCritical : LogColors.marker
        let h = bounds.height, w = bounds.width
        let attrs = LogColors.attrBold(color)
        let size = (line.message as NSString).size(withAttributes: attrs)
        let tx = (w - size.width) / 2
        let ty = (h - LogColors.lineHeight) / 2
        line.message.draw(at: NSPoint(x: tx, y: ty), withAttributes: attrs)
        // rules either side of the centred label
        color.withAlphaComponent(0.45).setFill()
        let ruleY = h / 2
        NSRect(x: 12, y: ruleY, width: max(0, tx - 12 - 10), height: 1).fill()
        NSRect(x: tx + size.width + 10, y: ruleY, width: max(0, w - (tx + size.width) - 10 - 12), height: 1).fill()
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
