import SwiftUI
import Lemonade
import AppKit

/// SQL mode (reqs 13–14): a syntax-highlighted, autocompleting SQL editor that acts as a **live
/// filter on the log list**. The query must SELECT an `insert_id` column (stable across poll
/// restarts; `seq` works too as a fallback); the matching rows show in the same fast log table
/// below, re-running every couple of seconds as new logs arrive. A schema reference and a
/// label-filter helper make it clear how to query.
struct CloudSqlEditorBar: View {
    @Bindable var session: CloudLogSession
    @State private var showSave = false
    @State private var saveName = ""
    @State private var showSchema = false
    /// Set by the editor — inserts text at the cursor (schema/label helpers use it).
    @State private var insert: ((String) -> Void)?

    private var registry: CloudLoggingRegistry { session.registry }
    private let columnColor = Color(red: 0.20, green: 0.60, blue: 0.62)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LemonadeUi.Text(statusText, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary, maxLines: 1)
                Spacer()
                labelsMenu
                schemaButton
                templatesMenu
                LemonadeUi.Button(label: "Save…", onClick: { saveName = ""; showSave = true },
                                  variant: .neutral, type: .subtle, size: .xSmall).fixedSize()
                LemonadeUi.Button(label: session.sqlRunning ? "Running…" : "Run", onClick: { session.runSQL() },
                                  leadingIcon: .chevronRight, variant: .primary, type: .subtle, size: .xSmall).fixedSize()
            }
            SqlEditorView(text: $session.sqlText, onRun: { session.runSQL() }, insertHook: $insert)
                .frame(height: 132)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(LemonadeTheme.colors.border.borderNeutralLow, lineWidth: 1))
                .onChange(of: session.sqlText) { _, new in session.noteSqlTextChanged(new) }
            HStack(spacing: 8) {
                if let error = session.sqlError {
                    LemonadeUi.Text(error, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                    color: LemonadeTheme.colors.content.contentCritical, maxLines: 2)
                } else {
                    LemonadeUi.Text("⌘↩ to run · keep an `insert_id` column · labels: json_extract(labels_json,'$.key')",
                                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                    color: LemonadeTheme.colors.content.contentTertiary, maxLines: 1)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(LemonadeTheme.colors.background.bgElevated)
        .alert("Save SQL template", isPresented: $showSave) {
            TextField("Template name", text: $saveName)
            Button("Save") { registry.saveSqlTemplate(name: saveName, sql: session.sqlText) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var statusText: String {
        "SQL filter · \(session.sqlMatchCount) shown · re-runs live"
    }

    private var labelsMenu: some View {
        Menu {
            if session.labelKeys.isEmpty {
                Text("No labels detected yet — run a session once")
            } else {
                Section("Insert a label filter") {
                    ForEach(session.labelKeys, id: \.self) { key in
                        Button(key) { insert?(CloudSqlSchema.labelFilter(key: key)) }
                    }
                }
            }
        } label: {
            menuLabel(icon: "tag", title: "Labels")
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var schemaButton: some View {
        Button(action: { showSchema = true }) { menuLabel(icon: "tablecells", title: "Schema") }
            .buttonStyle(.plain)
            .popover(isPresented: $showSchema, arrowEdge: .bottom) { schemaPopover }
    }

    private var schemaPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            LemonadeUi.Text("TABLE  log_entry  —  click a column to insert it",
                            textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(CloudSqlSchema.columns, id: \.name) { col in
                        Button(action: { insert?(col.name); showSchema = false }) {
                            HStack(alignment: .top, spacing: 8) {
                                Text(col.name)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(columnColor)
                                    .frame(width: 150, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(col.type).font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                                    Text(col.note).font(.system(size: 10))
                                        .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
                    }
                }
            }
            .frame(height: 360)
        }
        .frame(width: 440)
    }

    private var templatesMenu: some View {
        Menu {
            if !registry.sqlTemplates.isEmpty {
                Section("Saved") {
                    ForEach(registry.sqlTemplates) { template in
                        Button(template.name) { session.applySqlText(template.sql) }
                    }
                }
            }
            Section("Starters") {
                ForEach(Array(CloudSqlTemplates.all.enumerated()), id: \.offset) { _, item in
                    Button(item.label) { session.applySqlText(item.sql) }
                }
            }
            Divider()
            Button("From current filter") { session.regenerateSQL(); session.runSQL() }
        } label: {
            menuLabel(icon: "doc.text", title: "Templates")
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func menuLabel(icon: String, title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11))
            Text(title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
    }
}
