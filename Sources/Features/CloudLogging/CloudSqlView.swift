import SwiftUI
import Lemonade
import AppKit

/// SQL mode (reqs 13–14): a read-only SQL editor that acts as a **live filter on the log list**.
/// The query must SELECT a `seq` column; the matching rows are shown in the same fast log table
/// below (driven by `session.visible`), and it re-runs every couple of seconds so the polling
/// system keeps feeding it. Switching back to Logs removes the filter. Saved/starter templates
/// are available, plus "From current filter" to regenerate from the structured query.
struct CloudSqlEditorBar: View {
    @Bindable var session: CloudLogSession
    @State private var showSave = false
    @State private var saveName = ""

    private var registry: CloudLoggingRegistry { session.registry }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LemonadeUi.Text(statusText, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary, maxLines: 1)
                Spacer()
                templatesMenu
                LemonadeUi.Button(label: "Save…", onClick: { saveName = ""; showSave = true },
                                  variant: .neutral, type: .subtle, size: .xSmall).fixedSize()
                LemonadeUi.Button(label: session.sqlRunning ? "Running…" : "Run", onClick: { session.runSQL() },
                                  leadingIcon: .chevronRight, variant: .primary, type: .subtle, size: .xSmall).fixedSize()
            }
            TextField("SELECT seq, … FROM log_entry", text: $session.sqlText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(2...10)
                .padding(.vertical, 7).padding(.horizontal, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(LemonadeTheme.colors.background.bgNeutralSubtle))
                .onChange(of: session.sqlText) { _, new in session.noteSqlTextChanged(new) }
            if let error = session.sqlError {
                LemonadeUi.Text(error, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentCritical, maxLines: 3)
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
        "SQL filter · \(session.sqlMatchCount) matching · re-runs live as new logs arrive"
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
            HStack(spacing: 4) {
                Image(systemName: "doc.text").font(.system(size: 11))
                Text("Templates").font(.system(size: 11, weight: .medium))
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }
}
