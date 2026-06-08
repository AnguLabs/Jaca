import SwiftUI
import Lemonade
import AppKit

/// The active tab's content: filter/transport toolbar, the live log list, and a
/// status bar. Filtering, follow-tail, clear and export all act on the session.
struct LogSessionView: View {
    @Bindable var session: LogSession

    @State private var searchText = ""
    @State private var packageText = ""
    @State private var searchDebounce: Task<Void, Never>?
    @State private var packageDebounce: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            border
            LogListView(session: session)
            border
            StatusBarView(session: session)
        }
        .background(LemonadeTheme.colors.background.bgDefault)
        .accessibilityIdentifier("logSessionView")
        .onAppear {
            searchText = session.filter.query
            packageText = session.filter.packageLabel
        }
    }

    private var border: some View {
        Rectangle()
            .fill(LemonadeTheme.colors.border.borderNeutralLow)
            .frame(height: 1)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing200) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                transportButton
                clearMenu
                followButton
                Spacer()
                if let status = session.statusMessage {
                    LemonadeUi.Text(
                        status,
                        textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                        color: LemonadeTheme.colors.content.contentCritical,
                        maxLines: 1
                    )
                }
                LemonadeUi.IconButton(icon: .download, contentDescription: "Export") {
                    exportLog()
                }
            }
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                levelChips
                LemonadeUi.Chip(
                    label: ".*",
                    selected: session.filter.isRegex,
                    onChipClicked: { session.setRegex(!session.filter.isRegex) }
                )
                searchField
                HStack(spacing: 2) {
                    packageField
                    PackagePicker(session: session, packageText: $packageText) { id in
                        packageText = id
                        session.setPackage(id)
                    }
                }
            }
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing200)
        .background(LemonadeTheme.colors.background.bgElevated)
    }

    private var clearMenu: some View {
        Menu {
            Button("Clear view", action: { session.clear() })
            if session.device.platform == .android {
                Button("Clear device buffer", action: { session.clearDeviceBuffer() })
            }
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Clear")
        .accessibilityLabel("Clear")
        .accessibilityIdentifier("clearMenu")
    }

    private var transportButton: some View {
        Button(action: { session.toggle() }) {
            Image(systemName: session.isRunning ? "stop.fill" : "play.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(
                    session.isRunning
                        ? LemonadeTheme.colors.content.contentCritical
                        : LemonadeTheme.colors.content.contentBrand
                )
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                        .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
                )
        }
        .buttonStyle(.plain)
        .help(session.isRunning ? "Stop" : "Start")
        .accessibilityLabel(session.isRunning ? "Stop" : "Start")
        .accessibilityIdentifier("logTransportButton")
    }

    private var followButton: some View {
        Button(action: { session.followTail.toggle() }) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    session.followTail
                        ? LemonadeTheme.colors.content.contentBrand
                        : LemonadeTheme.colors.content.contentSecondary
                )
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                        .fill(session.followTail
                            ? LemonadeTheme.colors.background.bgBrandSubtle
                            : LemonadeTheme.colors.background.bgNeutralSubtle)
                )
        }
        .buttonStyle(.plain)
        .help("Follow tail")
        .accessibilityLabel("Follow tail")
        .accessibilityIdentifier("followButton")
    }

    private var levelChips: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing100) {
            ForEach(LogLevel.allCases, id: \.self) { level in
                LemonadeUi.Chip(
                    label: level.short,
                    selected: session.filter.minLevel == level,
                    onChipClicked: { session.setMinLevel(level) }
                )
                .accessibilityIdentifier("level-\(level.short)")
            }
        }
    }

    private var searchField: some View {
        LemonadeUi.SearchField(
            input: $searchText,
            onInputChanged: { value in debounceSearch(value) },
            placeholder: session.filter.isRegex ? "regex…" : "filter text…",
            onInputClear: { session.setQuery("") }
        )
        .frame(maxWidth: 320)
    }

    private var packageField: some View {
        LemonadeUi.SearchField(
            input: $packageText,
            onInputChanged: { value in debouncePackage(value) },
            placeholder: "package id…",
            onInputClear: { session.setPackage("") }
        )
        .frame(maxWidth: 220)
    }

    private func debounceSearch(_ value: String) {
        searchDebounce?.cancel()
        searchDebounce = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            session.setQuery(value)
        }
    }

    private func debouncePackage(_ value: String) {
        packageDebounce?.cancel()
        packageDebounce = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            session.setPackage(value.trimmingCharacters(in: .whitespaces))
        }
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

// MARK: - Package / app picker

/// Dropdown of installed apps/packages on the device. Selecting one applies it as
/// the package filter; includes a live search and an "all processes" reset.
private struct PackagePicker: View {
    let session: LogSession
    @Binding var packageText: String
    let onSelect: (String) -> Void

    @State private var show = false
    @State private var apps: [AppEntry] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var query = ""

    var body: some View {
        Button(action: { show = true; if !loaded { load() } }) {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        }
        .buttonStyle(.plain)
        .help("Choose app / package")
        .accessibilityLabel("Choose app or package")
        .accessibilityIdentifier("packagePicker")
        .popover(isPresented: $show, arrowEdge: .bottom) { popover }
    }

    private var filtered: [AppEntry] {
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.id.localizedCaseInsensitiveContains(query)
                || ($0.name ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private var popover: some View {
        VStack(spacing: 0) {
            TextField("Search apps…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(LemonadeTheme.spaces.spacing200)
                .accessibilityIdentifier("appSearch")

            Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)

            if loading {
                ProgressView().padding(LemonadeTheme.spaces.spacing400)
                    .frame(maxWidth: .infinity)
            } else if apps.isEmpty {
                LemonadeUi.Text("No apps found on this device.",
                                textStyle: LemonadeTypography.shared.bodySmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary)
                    .padding(LemonadeTheme.spaces.spacing400)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        row(title: "All processes", subtitle: nil, isUser: false) { select("") }
                        ForEach(filtered) { app in
                            row(title: app.display,
                                subtitle: app.name != nil ? app.id : nil,
                                isUser: app.isUserApp) { select(app.id) }
                        }
                    }
                }
            }
        }
        .frame(width: 340, height: 380)
    }

    private func row(title: String, subtitle: String?, isUser: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                Circle()
                    .fill(isUser ? LemonadeTheme.colors.content.contentBrand : Color.clear)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing300)
            .padding(.vertical, LemonadeTheme.spaces.spacing100)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("appRow")
    }

    private func load() {
        loading = true
        // @MainActor so the @State mutations below never happen off the main thread.
        Task { @MainActor in
            let result = await session.installedApps()
            apps = result
            loaded = true
            loading = false
        }
    }

    private func select(_ id: String) {
        // Dismiss the popover first, then apply the filter on the next runloop —
        // mutating ancestor state while the popover tears down can crash on macOS.
        show = false
        DispatchQueue.main.async { onSelect(id) }
    }
}

// MARK: - Log list

private struct BottomAnchorKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Virtualized, monospaced log list. Auto-scrolls while following the tail, and
/// auto-pauses follow when the user scrolls up (resumes when scrolled back down).
private struct LogListView: View {
    let session: LogSession
    private let bottomID = "log-bottom-anchor"

    // Multi-row selection (by line seq). Click selects; ⇧-click extends a range;
    // ⌘-click toggles. ⌘C copies the selected messages.
    @State private var selection: Set<UInt64> = []
    @State private var anchor: UInt64?

    // Only render the most recent slice so the ForEach never diffs 100k rows; the
    // full buffer is still kept for filtering/selection/export.
    private let renderCap = 5_000
    private var displayed: ArraySlice<LogLine> { session.visible.suffix(renderCap) }

    private var selectedLines: [LogLine] { session.visible.filter { selection.contains($0.seq) } }

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(displayed) { line in
                            LogRowView(line: line, isSelected: selection.contains(line.seq))
                                .padding(.horizontal, LemonadeTheme.spaces.spacing300)
                                .contentShape(Rectangle())
                                .onTapGesture { handleClick(line) }
                                .contextMenu { rowMenu(for: line) }
                                .id(line.seq)
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                            .background(GeometryReader { g in
                                Color.clear.preference(
                                    key: BottomAnchorKey.self,
                                    value: g.frame(in: .named("logScroll")).minY
                                )
                            })
                    }
                    .padding(.vertical, LemonadeTheme.spaces.spacing100)
                }
                .coordinateSpace(name: "logScroll")
                .background(LemonadeTheme.colors.background.bgDefault)
                .onChange(of: session.visible.count) {
                    if session.followTail { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onChange(of: session.followTail) {
                    if session.followTail { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onPreferenceChange(BottomAnchorKey.self) { minY in
                    // minY is the bottom anchor's position within the visible area.
                    let viewport = outer.size.height
                    DispatchQueue.main.async {
                        if minY > viewport + 80, session.followTail {
                            session.followTail = false      // user scrolled up
                        } else if minY <= viewport + 8, !session.followTail {
                            session.followTail = true       // back at bottom
                        }
                    }
                }
                // ⌘C copies the selected messages (only enabled with a selection, so
                // it doesn't shadow Copy in the search field).
                .background {
                    Button("") { copy(selectedLines, messagesOnly: true) }
                        .keyboardShortcut("c", modifiers: .command)
                        .disabled(selection.isEmpty)
                        .hidden()
                }
            }
        }
    }

    // MARK: - Selection & copy

    private func handleClick(_ line: LogLine) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift), let anchor {
            let seqs = session.visible.map(\.seq)   // O(n) — only on ⇧-click
            if let a = seqs.firstIndex(of: anchor), let b = seqs.firstIndex(of: line.seq) {
                let range = a <= b ? a...b : b...a
                selection = Set(seqs[range])
            }
        } else if mods.contains(.command) {
            if selection.contains(line.seq) { selection.remove(line.seq) } else { selection.insert(line.seq) }
            anchor = line.seq
        } else {
            selection = [line.seq]
            anchor = line.seq
        }
    }

    @ViewBuilder
    private func rowMenu(for line: LogLine) -> some View {
        // Act on the selection if the right-clicked row is part of it, else just this row.
        let target = selection.contains(line.seq) && selection.count > 1 ? selectedLines : [line]
        let n = target.count
        Button(n > 1 ? "Copy \(n) Messages" : "Copy Message") { copy(target, messagesOnly: true) }
        Button(n > 1 ? "Copy \(n) Lines (with time & tag)" : "Copy Line") { copy(target, messagesOnly: false) }
        Divider()
        Button("Select All") {
            selection = Set(session.visible.map(\.seq))
            anchor = session.visible.last?.seq
        }
        if !selection.isEmpty {
            Button("Deselect") { selection.removeAll(); anchor = nil }
        }
    }

    private func copy(_ lines: [LogLine], messagesOnly: Bool) {
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(LogClipboard.text(for: lines, messagesOnly: messagesOnly), forType: .string)
    }
}

// MARK: - Status bar

private struct StatusBarView: View {
    let session: LogSession

    var body: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing300) {
            statusDot
            metric("\(session.visible.count) shown")
            metric("\(session.totalCount) total")
            if session.droppedCount > 0 {
                metric("\(session.droppedCount) dropped")
            }
            Spacer()
            metric(session.device.displayModel)
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing100)
        .background(LemonadeTheme.colors.background.bgElevated)
    }

    private var statusDot: some View {
        Circle()
            .fill(session.isRunning
                ? LemonadeTheme.colors.content.contentPositive
                : LemonadeTheme.colors.content.contentTertiary)
            .frame(width: 8, height: 8)
    }

    private func metric(_ text: String) -> some View {
        LemonadeUi.Text(
            text,
            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
            color: LemonadeTheme.colors.content.contentSecondary,
            maxLines: 1
        )
    }
}
