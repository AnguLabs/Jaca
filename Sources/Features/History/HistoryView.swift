import SwiftUI
import Lemonade

/// Read-only browser over saved history: pick a device+package group, then a
/// past session, and view (and full-text search) its persisted lines. Answers
/// "show me all logcat for this app on this device across sessions".
struct HistoryView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var groups: [PackageGroup] = []
    @State private var selectedGroup: PackageGroup.ID?
    @State private var sessions: [SessionRecord] = []
    @State private var selectedSession: SessionRecord.ID?
    @State private var lines: [LogLine] = []
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
            HSplitView {
                groupsPane.frame(minWidth: 220, idealWidth: 240)
                sessionsPane.frame(minWidth: 220, idealWidth: 260)
                linesPane.frame(minWidth: 360)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(LemonadeTheme.colors.background.bgDefault)
        .task { groups = await model.history?.packageGroups() ?? [] }
        .task(id: selectedGroup) { await loadSessions() }
        .task(id: loadKey) { await loadLines() }
    }

    private var loadKey: String { "\(selectedSession ?? "")\u{1}\(searchText)" }

    private var header: some View {
        HStack {
            LemonadeUi.Text(
                "History",
                textStyle: LemonadeTypography.shared.headingSmall,
                color: LemonadeTheme.colors.content.contentPrimary
            )
            Spacer()
            LemonadeUi.Button(label: "Done", onClick: { dismiss() },
                              variant: .neutral, type: .subtle, size: .small)
        }
        .padding(LemonadeTheme.spaces.spacing300)
        .background(LemonadeTheme.colors.background.bgElevated)
    }

    private var groupsPane: some View {
        List(selection: $selectedGroup) {
            Section("Apps") {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        LemonadeUi.Text(
                            group.displayPackage,
                            textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                            color: LemonadeTheme.colors.content.contentPrimary, maxLines: 1
                        )
                        LemonadeUi.Text(
                            "\(group.model.isEmpty ? group.deviceID : group.model) · \(group.sessions) session(s)",
                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            color: LemonadeTheme.colors.content.contentTertiary, maxLines: 1
                        )
                    }
                    .tag(group.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var sessionsPane: some View {
        List(selection: $selectedSession) {
            Section("Sessions") {
                ForEach(sessions) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        LemonadeUi.Text(
                            session.displayName,
                            textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                            color: LemonadeTheme.colors.content.contentPrimary, maxLines: 1
                        )
                        LemonadeUi.Text(
                            "\(session.startedAt.formatted(date: .abbreviated, time: .standard)) · \(session.lineCount) lines",
                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            color: LemonadeTheme.colors.content.contentTertiary, maxLines: 1
                        )
                    }
                    .tag(session.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var linesPane: some View {
        VStack(spacing: 0) {
            LemonadeUi.SearchField(
                input: $searchText,
                placeholder: "Search this session…",
                onInputClear: { searchText = "" }
            )
            .padding(LemonadeTheme.spaces.spacing200)
            Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
            if selectedSession == nil {
                placeholder("Select a session to view its logs.")
            } else if lines.isEmpty {
                placeholder(searchText.isEmpty ? "No lines stored." : "No matches.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            LogRowView(line: line)
                                .padding(.horizontal, LemonadeTheme.spaces.spacing300)
                        }
                    }
                    .padding(.vertical, LemonadeTheme.spaces.spacing100)
                }
            }
        }
        .background(LemonadeTheme.colors.background.bgDefault)
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            LemonadeUi.Text(
                text, textStyle: LemonadeTypography.shared.bodySmallRegular,
                textAlign: .center, color: LemonadeTheme.colors.content.contentTertiary
            )
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private func loadSessions() async {
        guard let selectedGroup, let group = groups.first(where: { $0.id == selectedGroup }) else {
            sessions = []; selectedSession = nil; return
        }
        sessions = await model.history?.sessions(deviceID: group.deviceID, package: group.package) ?? []
        selectedSession = nil
        lines = []
    }

    private func loadLines() async {
        guard let selectedSession, let uuid = UUID(uuidString: selectedSession) else {
            lines = []; return
        }
        // Debounce search typing (task is cancelled & restarted when loadKey changes).
        if !searchText.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        let query = searchText.isEmpty ? nil : searchText
        lines = await model.history?.lines(sessionID: uuid, search: query) ?? []
    }
}
