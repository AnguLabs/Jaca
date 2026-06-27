import SwiftUI
import Lemonade
import AppKit

/// The active Cloud Logging tab: a toolbar (Start/Stop, log-name + time-range selectors,
/// severity quick-chips, instant search, the structured query builder, and a Logs/SQL switch)
/// over the virtualized log list with a right-side detail panel — or the SQL mode.
struct CloudLogSessionView: View {
    @Bindable var session: CloudLogSession
    var model: AppModel
    var isActive: Bool = true

    @State private var showFilters = false
    @State private var showLogNames = false
    @State private var showAbsolute = false
    @State private var customMinutes = false
    @State private var minutesText = "15"
    /// Local mirror of the search text that drives the SearchField. Lemonade's SearchField
    /// doesn't clear its own bound text when an `onInputClear` is supplied, and an @Observable
    /// binding through a focused TextField doesn't reliably redraw — so we own a @State here,
    /// forward edits to `session.searchText`, and reset both on clear.
    @State private var searchText = ""
    /// Width of the right-side detail panel, dragged via the divider handle.
    @State private var detailWidth: CGFloat = 380

    private var registry: CloudLoggingRegistry { session.registry }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            border
            if showFilters {
                CloudQueryBar(session: session)
                border
            }
            if session.viewMode == .sql {
                CloudSqlEditorBar(session: session)
                border
            }
            logsBody    // the same fast log table for both modes — SQL just filters `visible`
            border
            statusBar
        }
        .background(LemonadeTheme.colors.background.bgDefault)
        .accessibilityIdentifier("cloudLogSessionView")
        // The selected log name is GLOBAL (registry) — if another tab changes it, re-target.
        .onChange(of: session.selectedLogName) { _, _ in session.logNameChanged() }
        .sheet(isPresented: $showLogNames) {
            LogNameSheet(registry: registry, projectID: session.projectID)
        }
        .sheet(isPresented: $showAbsolute) {
            AbsoluteRangeSheet(session: session)
        }
        .alert("Custom range (minutes)", isPresented: $customMinutes) {
            TextField("Minutes", text: $minutesText)
            Button("Apply") {
                if let m = Int(minutesText), m > 0 { setRange(.last(minutes: m)) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing200) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                startStopButton
                clearButton
                followButton
                logNameSelector
                timeRangeMenu
                Spacer()
                if session.isLoading { ProgressView().controlSize(.small) }
                if let status = session.statusMessage {
                    LemonadeUi.Text(status, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                    color: LemonadeTheme.colors.content.contentCritical, maxLines: 1)
                }
                shareButton
                modeSwitch
            }
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                severityChips.disabled(session.rawFilter != nil)
                LemonadeUi.Chip(label: session.rawFilter != nil ? "URL filter" : "Filters",
                                selected: showFilters || !session.query.isEmpty || session.rawFilter != nil,
                                onChipClicked: { showFilters.toggle() })
                searchField
                Spacer()
                LemonadeUi.IconButton(icon: .download, contentDescription: "Export") { exportLog() }
            }
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing200)
        .background(LemonadeTheme.colors.background.bgElevated)
    }

    private var startStopButton: some View {
        Button(action: { session.toggle() }) {
            Image(systemName: session.isRunning ? "stop.fill" : "play.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(session.isRunning
                    ? LemonadeTheme.colors.content.contentCritical
                    : LemonadeTheme.colors.content.contentBrand)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        }
        .buttonStyle(.plain)
        .help(session.isRunning ? "Stop" : "Start")
        .accessibilityIdentifier("cloudTransportButton")
    }

    private var clearButton: some View {
        Button(action: { session.clear() }) {
            Image(systemName: "trash").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        }
        .buttonStyle(.plain).help("Clear view")
    }

    private var followButton: some View {
        Button(action: { session.followTail.toggle() }) {
            Image(systemName: "arrow.down.to.line").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(session.followTail
                    ? LemonadeTheme.colors.content.contentBrand
                    : LemonadeTheme.colors.content.contentSecondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(session.followTail
                        ? LemonadeTheme.colors.background.bgBrandSubtle
                        : LemonadeTheme.colors.background.bgNeutralSubtle))
        }
        .buttonStyle(.plain).help("Follow tail")
    }

    private var logNameSelector: some View {
        Button(action: { showLogNames = true }) {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 11, weight: .semibold))
                Text(session.selectedLogName.map(CloudLogName.shortId) ?? "Choose log name")
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(session.selectedLogName == nil
                ? LemonadeTheme.colors.content.contentSecondary
                : LemonadeTheme.colors.content.contentBrand)
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        }
        .buttonStyle(.plain)
        .help("Configure the log name (shared across this project's sessions)")
        .accessibilityIdentifier("cloudLogNameSelector")
    }

    private var timeRangeMenu: some View {
        Menu {
            ForEach(Array(CloudTimeRange.presets.enumerated()), id: \.offset) { _, preset in
                Button(preset.label) { setRange(.last(minutes: preset.minutes)) }
            }
            Divider()
            Button("Custom minutes…") { customMinutes = true }
            Button("Absolute range…") { showAbsolute = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "clock").font(.system(size: 11, weight: .semibold))
                Text(session.timeRange.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private var modeSwitch: some View {
        LemonadeUi.SegmentedControl(
            properties: [.label("Logs"), .label("SQL")],
            selectedTab: session.viewMode == .logs ? 0 : 1,
            size: .small,
            onTabSelected: { session.setViewMode($0 == 0 ? .logs : .sql) }
        )
        .fixedSize()
    }

    private var shareButton: some View {
        Menu {
            Button("Copy Logs Explorer URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.consoleURL(), forType: .string)
            }
            Button("Open in browser") {
                if let url = URL(string: session.consoleURL()) { NSWorkspace.shared.open(url) }
            }
        } label: {
            Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Share this filter as a Cloud Console Logs Explorer URL")
    }

    private var severityChips: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing100) {
            LemonadeUi.Chip(label: "All", selected: session.query.minSeverity == nil && session.query.severitySet.isEmpty,
                            onChipClicked: {
                session.query.minSeverity = nil; session.query.severitySet = []
                session.applyServerQuery()
            })
            ForEach(CloudSeverity.commonLadder, id: \.self) { severity in
                LemonadeUi.Chip(label: severity.short,
                                selected: session.query.severitySet.isEmpty && session.query.minSeverity == severity,
                                onChipClicked: {
                    session.query.severitySet = []; session.query.minSeverity = severity
                    session.applyServerQuery()
                })
            }
        }
    }

    private var searchField: some View {
        LemonadeUi.SearchField(
            input: $searchText,
            onInputChanged: { value in session.searchText = value },
            placeholder: "filter loaded logs…",
            onInputClear: {
                searchText = ""           // clear the field's own state so the UI updates
                session.searchText = ""   // clear the actual filter
            }
        )
        .frame(maxWidth: 320)
    }

    // MARK: - Body

    @ViewBuilder private var logsBody: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .top) {
                CloudLogTableView(session: session, isActive: isActive,
                                  revision: session.visible.count, epoch: session.listEpoch,
                                  follow: session.followTail, selectedSeq: session.selectedEntry?.seq)
                    .background(LemonadeTheme.colors.background.bgDefault)
                if session.visible.isEmpty {
                    emptyHint
                }
                if session.olderLoading {
                    olderLoadingBanner
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let entry = session.selectedEntry {
                DetailResizeHandle(width: $detailWidth, minWidth: 280, maxWidth: 900)
                CloudLogDetailPanel(session: session, entry: entry, onNewSession: openFork)
                    .frame(width: detailWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: session.selectedEntry?.seq)
    }

    /// Thin "loading older logs" indicator pinned to the top while a backward page is in flight.
    private var olderLoadingBanner: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            LemonadeUi.Text("Loading older logs…", textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            color: LemonadeTheme.colors.content.contentSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(LemonadeTheme.colors.background.bgElevated))
        .overlay(Capsule().strokeBorder(LemonadeTheme.colors.border.borderNeutralLow, lineWidth: 1))
        .padding(.top, 6)
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    private var emptyHint: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing200) {
            Image(systemName: "cloud").font(.system(size: 34))
                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
            LemonadeUi.Text(
                session.isRunning ? "Waiting for logs…"
                    : (session.totalCount == 0 ? "Press Start to stream Cloud Logging." : "No logs match the search."),
                textStyle: LemonadeTypography.shared.bodyMediumRegular,
                textAlign: .center,
                color: LemonadeTheme.colors.content.contentSecondary
            )
            if session.selectedLogName == nil && !session.isRunning {
                LemonadeUi.Button(label: "Choose a log name", onClick: { showLogNames = true },
                                  variant: .neutral, type: .subtle, size: .small).fixedSize()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LemonadeTheme.colors.background.bgDefault)
    }

    private var statusBar: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing300) {
            Circle().fill(session.isRunning
                ? LemonadeTheme.colors.content.contentPositive
                : LemonadeTheme.colors.content.contentTertiary)
                .frame(width: 8, height: 8)
            metric("\(session.visible.count) shown")
            metric("\(session.totalCount) total")
            if session.droppedCount > 0 { metric("\(session.droppedCount) dropped") }
            Spacer()
            GcloudDebugButton(compact: true)
            metric(session.projectTitle)
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing100)
        .background(LemonadeTheme.colors.background.bgElevated)
    }

    private func metric(_ text: String) -> some View {
        LemonadeUi.Text(text, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                        color: LemonadeTheme.colors.content.contentSecondary, maxLines: 1)
    }

    private var border: some View {
        Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
    }

    // MARK: - Actions

    private func setRange(_ range: CloudTimeRange) {
        session.timeRange = range
        session.applyServerQuery()
    }

    /// Opens a NEW tab pre-filtered by the clicked value, keeping this session intact, and starts
    /// streaming it immediately.
    private func openFork(_ fork: CloudSessionFork) {
        model.startCloudLogSession(
            projectID: session.projectID, autoStart: true,
            displayName: fork.name, query: fork.query,
            timeRange: session.timeRange, rawFilter: fork.rawFilter
        )
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.displayName).log"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? session.exportText().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Sheet to pick an absolute start/end window (req 8).
private struct AbsoluteRangeSheet: View {
    @Bindable var session: CloudLogSession
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date().addingTimeInterval(-3600)
    @State private var end = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
            LemonadeUi.Text("Absolute time range", textStyle: LemonadeTypography.shared.headingSmall,
                            color: LemonadeTheme.colors.content.contentPrimary)
            DatePicker("Start", selection: $start)
            DatePicker("End", selection: $end)
            HStack {
                Spacer()
                LemonadeUi.Button(label: "Cancel", onClick: { dismiss() },
                                  variant: .neutral, type: .subtle, size: .small).fixedSize()
                LemonadeUi.Button(label: "Apply", onClick: {
                    session.timeRange = .between(start: start, end: end)
                    session.applyServerQuery()
                    dismiss()
                }, variant: .primary, type: .solid, size: .small).fixedSize()
            }
        }
        .padding(LemonadeTheme.spaces.spacing600)
        .frame(width: 420)
        .background(LemonadeTheme.colors.background.bgDefault)
    }
}

/// A 1px divider with a wider invisible hit area: drag it left/right to resize the detail
/// panel (the pane to its right), and it shows a resize cursor on hover.
private struct DetailResizeHandle: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    @State private var dragStart: CGFloat?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering
                ? LemonadeTheme.colors.content.contentBrand
                : LemonadeTheme.colors.border.borderNeutralLow)
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if dragStart == nil { dragStart = width }
                                // Panel is to the right of the handle, so dragging left widens it.
                                let next = (dragStart ?? width) - value.translation.width
                                width = min(maxWidth, max(minWidth, next))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            )
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}
