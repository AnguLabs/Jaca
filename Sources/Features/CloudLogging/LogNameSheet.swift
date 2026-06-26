import SwiftUI
import Lemonade

/// The log-name configuration sheet (req 7). The selected log name is GLOBAL per project — set
/// it here and every open session for the project reflects it (the registry is the single source
/// of truth). Lists the available log names (from `gcloud logging logs list`, cached and
/// refreshable) and supports adding one manually.
struct LogNameSheet: View {
    @Bindable var registry: CloudLoggingRegistry
    let projectID: String
    @Environment(\.dismiss) private var dismiss

    @State private var refreshing = false
    @State private var manual = ""
    @State private var filter = ""

    private var project: CloudProject? { registry.project(projectID) }

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing300) {
            header
            manualRow
            Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
            list
        }
        .padding(LemonadeTheme.spaces.spacing500)
        .frame(width: 540, height: 560)
        .background(LemonadeTheme.colors.background.bgDefault)
        .onAppear { if (project?.logNames.isEmpty ?? true) { refresh() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing100) {
            HStack {
                LemonadeUi.Text("Log names",
                                textStyle: LemonadeTypography.shared.headingSmall,
                                color: LemonadeTheme.colors.content.contentPrimary)
                Spacer()
                if refreshing { ProgressView().controlSize(.small) }
                LemonadeUi.Button(label: "Refresh", onClick: { refresh() }, leadingIcon: .arrowRotateCw,
                                  variant: .neutral, type: .subtle, size: .small).fixedSize()
                LemonadeUi.Button(label: "Done", onClick: { dismiss() },
                                  variant: .neutral, type: .subtle, size: .small).fixedSize()
            }
            LemonadeUi.Text(
                "Selecting a log name applies it to every session for \(project?.title ?? projectID).",
                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                color: LemonadeTheme.colors.content.contentTertiary
            )
        }
    }

    private var manualRow: some View {
        HStack(spacing: 8) {
            TextField("Add a log name manually (e.g. stdout)…", text: $manual)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.vertical, 7).padding(.horizontal, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(LemonadeTheme.colors.background.bgNeutralSubtle))
                .onSubmit { addManual() }
            LemonadeUi.Button(label: "Add", onClick: { addManual() }, leadingIcon: .circleCheck,
                              variant: .primary, type: .subtle, size: .small)
                .fixedSize()
                .disabled(manual.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder private var list: some View {
        let names = filteredNames
        if names.isEmpty {
            VStack(spacing: LemonadeTheme.spaces.spacing200) {
                LemonadeUi.Text(
                    refreshing ? "Loading log names…" : "No log names found yet — Refresh, or add one manually above.",
                    textStyle: LemonadeTypography.shared.bodySmallRegular,
                    textAlign: .center,
                    color: LemonadeTheme.colors.content.contentTertiary
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if (project?.logNames.count ?? 0) > 8 {
                    TextField("Filter…", text: $filter)
                        .textFieldStyle(.roundedBorder)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(names, id: \.self) { name in
                            row(name)
                        }
                    }
                }
            }
        }
    }

    private var filteredNames: [String] {
        let names = project?.logNames ?? []
        guard !filter.isEmpty else { return names }
        return names.filter { CloudLogName.shortId($0).localizedCaseInsensitiveContains(filter) }
    }

    private func row(_ name: String) -> some View {
        let selected = project?.selectedLogName == name
        return Button(action: { registry.setSelectedLogName(name, for: projectID); dismiss() }) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected
                        ? LemonadeTheme.colors.content.contentBrand
                        : LemonadeTheme.colors.content.contentTertiary)
                Text(CloudLogName.shortId(name))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing200)
            .padding(.vertical, LemonadeTheme.spaces.spacing200)
            .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                .fill(selected ? LemonadeTheme.colors.background.bgBrandSubtle : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            await registry.refreshLogNames(for: projectID)
            refreshing = false
        }
    }

    private func addManual() {
        let raw = manual.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let full = CloudLogName.full(projectID: projectID, logName: raw)
        var names = project?.logNames ?? []
        if !names.contains(full) { names.append(full); names.sort(); registry.setLogNames(names, for: projectID) }
        registry.setSelectedLogName(full, for: projectID)
        manual = ""
        dismiss()
    }
}
