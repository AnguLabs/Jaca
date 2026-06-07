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
                packageField
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

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(session.visible) { line in
                            LogRowView(line: line)
                                .padding(.horizontal, LemonadeTheme.spaces.spacing300)
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
            }
        }
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
