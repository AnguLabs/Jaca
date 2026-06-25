import SwiftUI
import Lemonade

/// The "Database" tab: app picker → database/table pickers → a scrollable grid of rows
/// plus a read-only SQL box. A snapshot of a pulled copy; "Refresh" re-pulls.
struct DatabaseSessionView: View {
    @Bindable var session: DatabaseSession

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HorizontalDividerOrLine()
            if session.appID == nil {
                messageState("Pick an app to browse its local database.", critical: false)
            } else if let error = session.error, session.result == nil, session.tables.isEmpty {
                messageState(error, critical: true)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LemonadeTheme.colors.background.bgDefault)
    }

    // MARK: - Toolbar (app + db + table pickers, refresh)

    private var toolbar: some View {
        HStack(spacing: 10) {
            DatabaseAppPicker(session: session)
            if !session.databases.isEmpty {
                picker(title: "DB", selection: session.selectedDB?.name ?? "—",
                       items: session.databases.map(\.name)) { name in
                    if let db = session.databases.first(where: { $0.name == name }) { session.selectDatabase(db) }
                }
            }
            if !session.tables.isEmpty {
                picker(title: "Table", selection: session.selectedTable ?? "—",
                       items: session.tables.map { "\($0.name) (\($0.rowCount))" }) { label in
                    let name = String(label.prefix(while: { $0 != "(" })).trimmingCharacters(in: .whitespaces)
                    session.selectTable(name)
                }
            }
            Spacer()
            if session.loading { ProgressView().controlSize(.small) }
            if session.selectedDB != nil {
                LemonadeUi.Text("snapshot", textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary)
                LemonadeUi.Button(label: "Refresh", onClick: { session.refresh() }, leadingIcon: .arrowRotateCw,
                                  variant: .neutral, type: .subtle, size: .xSmall).fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func picker(title: String, selection: String, items: [String], onPick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 5) {
            LemonadeUi.Text(title, textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            Menu {
                ForEach(items, id: \.self) { item in Button(item) { onPick(item) } }
            } label: {
                Text(selection).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    // MARK: - Content (SQL box + grid)

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            sqlBar
            HorizontalDividerOrLine()
            if let rs = session.result {
                if rs.columns.isEmpty {
                    messageState("Query returned no columns.", critical: false)
                } else {
                    grid(rs)
                    if session.selectedTable != nil { paginationBar }
                }
            } else {
                messageState(session.loading ? "Loading…" : "No table selected.", critical: false)
            }
        }
    }

    private var sqlBar: some View {
        HStack(spacing: 8) {
            TextField("SELECT … (read-only)", text: $session.sqlText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1...3)
                .padding(.vertical, 6).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(LemonadeTheme.colors.background.bgNeutralSubtle))
                .onSubmit { session.runQuery() }
            LemonadeUi.Button(label: "Run", onClick: { session.runQuery() }, leadingIcon: .chevronRight,
                              variant: .primary, type: .subtle, size: .xSmall).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .bottomLeading) {
            if let error = session.error, session.result != nil {
                LemonadeUi.Text(error, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentCritical, maxLines: 2)
                    .padding(.horizontal, 12)
            }
        }
    }

    // A simple H+V scrollable grid: header row of columns, then value rows.
    private func grid(_ rs: DBResultSet) -> some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(rs.columns.enumerated()), id: \.offset) { _, col in
                        cell(col, header: true)
                    }
                }
                .background(LemonadeTheme.colors.background.bgNeutralSubtle)
                ForEach(Array(rs.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                            cell(value ?? "NULL", header: false, isNull: value == nil)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func cell(_ text: String, header: Bool, isNull: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: header ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(isNull ? LemonadeTheme.colors.content.contentTertiary
                             : LemonadeTheme.colors.content.contentPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: 180, alignment: .leading)
            .padding(.vertical, 5).padding(.horizontal, 8)
            .overlay(Rectangle().frame(width: 1).frame(maxHeight: .infinity)
                .foregroundStyle(LemonadeTheme.colors.border.borderNeutralLow), alignment: .trailing)
            .overlay(Rectangle().frame(height: 1).frame(maxWidth: .infinity)
                .foregroundStyle(LemonadeTheme.colors.border.borderNeutralLow), alignment: .bottom)
    }

    private var paginationBar: some View {
        HStack(spacing: 10) {
            LemonadeUi.Button(label: "Prev", onClick: { session.prevPage() }, leadingIcon: .arrowLeft,
                              variant: .neutral, type: .subtle, size: .xSmall).fixedSize()
                .disabled(session.page == 0)
            LemonadeUi.Text("page \(session.page + 1)", textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            color: LemonadeTheme.colors.content.contentSecondary)
            LemonadeUi.Button(label: "Next", onClick: { session.nextPage() }, leadingIcon: .arrowRight,
                              variant: .neutral, type: .subtle, size: .xSmall).fixedSize()
                .disabled(!session.hasNextPage)
            Spacer()
            if let rs = session.result {
                LemonadeUi.Text("\(rs.rows.count) rows", textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    // MARK: - Helpers

    private func messageState(_ text: String, critical: Bool) -> some View {
        LemonadeUi.Text(text, textStyle: LemonadeTypography.shared.bodyMediumRegular, textAlign: .center,
                        color: critical ? LemonadeTheme.colors.content.contentCritical
                                        : LemonadeTheme.colors.content.contentSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
}

/// The app picker for the Database tab, mirroring the Network inspector's: a toolbar
/// button ("Pick an app" until chosen) that opens a searchable popover of installed apps.
/// Nothing loads until the user picks one.
private struct DatabaseAppPicker: View {
    @Bindable var session: DatabaseSession
    @State private var show = false
    @State private var query = ""

    var body: some View {
        Button(action: { show = true; session.loadApps() }) {
            HStack(spacing: 5) {
                Image(systemName: "ladybug").font(.system(size: 11, weight: .semibold))
                Text(buttonLabel).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(session.appID == nil
                ? LemonadeTheme.colors.content.contentSecondary
                : LemonadeTheme.colors.content.contentBrand)
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        }
        .buttonStyle(.plain)
        .help("Choose an app to browse its local database")
        .accessibilityIdentifier("dbAppPicker")
        .popover(isPresented: $show, arrowEdge: .bottom) { popover }
    }

    private var buttonLabel: String {
        guard let id = session.appID else { return "Pick an app" }
        if let app = session.apps.first(where: { $0.id == id }), let n = app.name { return n }
        return id.components(separatedBy: ".").last ?? id
    }

    private var sorted: [AppEntry] {
        let f = query.isEmpty ? session.apps : session.apps.filter {
            $0.id.localizedCaseInsensitiveContains(query) || ($0.name ?? "").localizedCaseInsensitiveContains(query)
        }
        return f.sorted { a, b in
            if a.isUserApp != b.isUserApp { return a.isUserApp }   // user apps first
            return a.display.localizedCaseInsensitiveCompare(b.display) == .orderedAscending
        }
    }

    private var popover: some View {
        VStack(spacing: 0) {
            TextField("Search apps…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(LemonadeTheme.spaces.spacing200)
                .accessibilityIdentifier("dbAppSearch")
            Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if session.loading && session.apps.isEmpty {
                        ProgressView().padding(LemonadeTheme.spaces.spacing400).frame(maxWidth: .infinity)
                    }
                    ForEach(sorted) { app in
                        row(title: app.display, subtitle: app.name != nil ? app.id : nil,
                            selected: session.appID == app.id) {
                            show = false
                            session.selectApp(app.id)
                        }
                    }
                }
            }
        }
        .frame(width: 360, height: 420)
    }

    private func row(title: String, subtitle: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                        .font(.system(size: 12)).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                            .font(.system(size: 10, design: .monospaced)).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LemonadeTheme.colors.content.contentBrand)
                }
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing300)
            .padding(.vertical, LemonadeTheme.spaces.spacing100)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dbAppRow")
    }
}

/// A 1px divider (Lemonade's HorizontalDivider name varies across versions; this is local).
private struct HorizontalDividerOrLine: View {
    var body: some View {
        Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
    }
}
