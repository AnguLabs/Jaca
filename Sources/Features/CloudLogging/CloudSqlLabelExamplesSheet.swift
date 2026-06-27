import SwiftUI
import Lemonade

/// Configures how many distinct example values of each label key are sent to the Claude SQL
/// assistant — cached per log name in `~/.jaca`. Default is one (just enough to teach the format);
/// a low-cardinality key like `tag` can be set to "All", a high-cardinality one like `user_id`
/// kept at one. The "All" toggle disables the count for that row.
struct CloudSqlLabelExamplesSheet: View {
    let session: CloudLogSession
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [Row] = []
    @State private var rules: [String: LabelExampleRule] = [:]
    @State private var loading = true

    struct Row: Identifiable {
        let key: String
        let scope: String
        let distinctValues: Int
        var id: String { key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
            header
            LemonadeUi.Text("How many example values of each label to send to Claude, so it learns the "
                            + "format. Default is 1. Set a low-cardinality label (e.g. tag) to All; keep a "
                            + "high-cardinality one (e.g. user_id) at 1.",
                            textStyle: LemonadeTypography.shared.bodySmallRegular,
                            color: LemonadeTheme.colors.content.contentSecondary)
            content
            footer
        }
        .padding(LemonadeTheme.spaces.spacing600)
        .frame(width: 560)
        .background(LemonadeTheme.colors.background.bgDefault)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3").foregroundStyle(LemonadeTheme.colors.content.contentBrand)
            LemonadeUi.Text("Label examples for Claude",
                            textStyle: LemonadeTypography.shared.headingSmall,
                            color: LemonadeTheme.colors.content.contentPrimary)
            Spacer()
            LemonadeUi.Button(label: "Cancel", onClick: { dismiss() },
                              variant: .neutral, type: .subtle, size: .small)
        }
    }

    @ViewBuilder private var content: some View {
        if loading {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.frame(height: 120)
        } else if rows.isEmpty {
            LemonadeUi.Notice(content: "No labels detected yet — capture some logs first.", voice: .info)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        ruleRow(row)
                        if row.id != rows.last?.id {
                            Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(LemonadeTheme.colors.border.borderNeutralLow, lineWidth: 1))
        }
    }

    private func ruleRow(_ row: Row) -> some View {
        let isAll = rules[row.key]?.all ?? false
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.key).font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                Text("\(row.scope) · \(row.distinctValues) value\(row.distinctValues == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
            }
            Spacer()
            Toggle("All", isOn: allBinding(row.key))
                .toggleStyle(.switch).controlSize(.mini).fixedSize()
            Stepper(value: countBinding(row.key, max: max(1, row.distinctValues)), in: 1...max(1, row.distinctValues)) {
                Text(isAll ? "all" : "\(rules[row.key]?.count ?? 1)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isAll ? LemonadeTheme.colors.content.contentTertiary
                                           : LemonadeTheme.colors.content.contentPrimary)
                    .frame(width: 28, alignment: .trailing)
            }
            .disabled(isAll || row.distinctValues <= 1)
            .opacity(isAll ? 0.45 : 1)
            .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Spacer()
            LemonadeUi.Button(label: "Save", onClick: { save() },
                              leadingIcon: .circleCheck, variant: .primary, type: .solid, size: .medium)
                .fixedSize()
                .disabled(loading)
        }
    }

    // MARK: - Bindings

    private func allBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { rules[key]?.all ?? false },
            set: { rules[key, default: .default].all = $0 }
        )
    }

    private func countBinding(_ key: String, max: Int) -> Binding<Int> {
        Binding(
            get: { rules[key]?.count ?? 1 },
            set: { rules[key, default: .default].count = Swift.min(Swift.max(1, $0), max) }
        )
    }

    // MARK: - Load / save

    private func load() async {
        rules = session.registry.labelExampleRules(project: session.projectID, logName: session.selectedLogName ?? "")
        let cardinalities = await session.labelCardinalities()
        // Merge by bare key (a key in both label scopes shares one rule); show the larger count.
        var byKey: [String: Row] = [:]
        for c in cardinalities {
            if let existing = byKey[c.key], existing.distinctValues >= c.distinctValues { continue }
            byKey[c.key] = Row(key: c.key, scope: c.scope, distinctValues: c.distinctValues)
        }
        rows = byKey.values.sorted { $0.key < $1.key }
        loading = false
    }

    private func save() {
        // Persist only non-default rules so the cache stays small.
        let pruned = rules.filter { $0.value != .default }
        session.registry.setLabelExampleRules(pruned, project: session.projectID, logName: session.selectedLogName ?? "")
        dismiss()
    }
}
