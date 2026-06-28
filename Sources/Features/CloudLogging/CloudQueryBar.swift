import SwiftUI
import Lemonade

/// The point-and-click query builder (req 9). Edits the session's structured `CloudLogQuery`
/// (textPayload / severity / labels), shows the generated Cloud Logging filter for the curious,
/// and applies it by restarting the poll (server-side filter). Designed to keep the user out of
/// the raw query language.
struct CloudQueryBar: View {
    @Bindable var session: CloudLogSession
    @State private var showRaw = false
    @State private var showSave = false
    @State private var templateName = ""

    private var registry: CloudLoggingRegistry { session.registry }

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing300) {
            if session.rawFilter != nil {
                rawSection
            } else {
                textSection
                severitySection
                labelSection
            }
            footer
            if showRaw { rawView }
        }
        .padding(LemonadeTheme.spaces.spacing300)
        .background(LemonadeTheme.colors.background.bgElevated)
        .alert("Save query template", isPresented: $showSave) {
            TextField("Template name", text: $templateName)
            Button("Save") {
                registry.saveQueryTemplate(name: templateName, query: session.query, rawFilter: session.rawFilter)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var rawSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("RAW FILTER (from URL)") {
                LemonadeUi.Button(label: "Use builder instead",
                                  onClick: { session.rawFilter = nil; session.applyServerQuery() },
                                  variant: .neutral, type: .subtle, size: .xSmall).fixedSize()
            }
            TextField("Cloud Logging filter…", text: rawBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(2...6)
                .padding(.vertical, 6).padding(.horizontal, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        }
    }

    private var rawBinding: Binding<String> {
        Binding(get: { session.rawFilter ?? "" }, set: { session.rawFilter = $0 })
    }

    // MARK: textPayload (req 9.1)

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("TEXT PAYLOAD") {}
            ForEach(Array(session.query.textConditions.enumerated()), id: \.element.id) { index, _ in
                HStack(spacing: 6) {
                    matchModeMenu($session.query.textConditions[index].mode)
                    valueField("text…", $session.query.textConditions[index].value)
                    if session.query.textConditions[index].mode == .regex {
                        CloudRegexAssistantButton(value: $session.query.textConditions[index].value,
                                                  field: "the log message (textPayload)")
                    }
                    removeButton { session.query.textConditions.remove(at: index) }
                }
                // The OR/AND combiner sits *between* conditions, so it's obvious they're combined.
                if index < session.query.textConditions.count - 1 {
                    HStack(spacing: 6) {
                        combineToggle($session.query.textCombineOr)
                        hint(session.query.textCombineOr ? "match any of these" : "match all of these")
                        Spacer()
                    }
                    .padding(.leading, 2)
                }
            }
            addInlineButton(session.query.textConditions.isEmpty
                            ? "Add a text filter"
                            : (session.query.textCombineOr ? "Add another (OR)" : "Add another (AND)")) {
                session.query.textConditions.append(TextCondition())
            }
        }
    }

    private func addInlineButton(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus.circle.fill").font(.system(size: 12))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(LemonadeTheme.colors.content.contentBrand)
        }
        .buttonStyle(.plain)
    }

    // MARK: severity (req 9.2)

    private var severitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("MIN SEVERITY") {}
            HStack(spacing: LemonadeTheme.spaces.spacing100) {
                LemonadeUi.Chip(label: "Any", selected: session.query.minSeverity == nil && session.query.severitySet.isEmpty,
                                onChipClicked: {
                    session.query.minSeverity = nil
                    session.query.severitySet = []
                })
                ForEach(CloudSeverity.commonLadder, id: \.self) { severity in
                    LemonadeUi.Chip(
                        label: severity.name,
                        selected: session.query.severitySet.isEmpty && session.query.minSeverity == severity,
                        onChipClicked: {
                            session.query.severitySet = []
                            session.query.minSeverity = severity
                        }
                    )
                }
            }
        }
    }

    // MARK: labels (req 9.3, keys auto-detected)

    private var labelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LemonadeUi.Text("LABELS", textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                                color: LemonadeTheme.colors.content.contentTertiary)
                addButton {
                    let key = session.labelKeys.first ?? ""
                    session.query.labelConditions.append(LabelCondition(key: key))
                }
                .disabled(session.labelKeys.isEmpty)
                Spacer()
                if session.query.labelConditions.count > 1 { combineToggle($session.query.labelCombineOr) }
            }
            if session.labelKeys.isEmpty {
                hint("No labels detected yet — run a session once so Jaca can auto-detect this log's label keys.")
            } else {
                ForEach(Array(session.query.labelConditions.enumerated()), id: \.element.id) { index, _ in
                    HStack(spacing: 6) {
                        LabelKeyPicker(session: session, selectedKey: $session.query.labelConditions[index].key)
                        matchModeMenu($session.query.labelConditions[index].mode)
                        valueField("value…", $session.query.labelConditions[index].value)
                        if session.query.labelConditions[index].mode == .regex {
                            let key = session.query.labelConditions[index].key
                            CloudRegexAssistantButton(value: $session.query.labelConditions[index].value,
                                                      field: key.isEmpty ? "a label value" : "labels.\(key)")
                        }
                        removeButton { session.query.labelConditions.remove(at: index) }
                    }
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            LemonadeUi.Button(label: session.isRunning ? "Apply (restart)" : "Apply",
                              onClick: { session.applyServerQuery() },
                              leadingIcon: .chevronRight, variant: .primary, type: .solid, size: .small)
                .fixedSize()
            LemonadeUi.Button(label: "Reset",
                              onClick: { session.query = CloudLogQuery(); session.rawFilter = nil; session.applyServerQuery() },
                              variant: .neutral, type: .subtle, size: .small)
                .fixedSize()
            templatesMenu
            Spacer()
            LemonadeUi.Button(label: showRaw ? "Hide query" : "Show query",
                              onClick: { showRaw.toggle() },
                              variant: .neutral, type: .subtle, size: .small)
                .fixedSize()
        }
    }

    private var templatesMenu: some View {
        Menu {
            if !registry.queryTemplates.isEmpty {
                Section("Saved") {
                    ForEach(registry.queryTemplates) { template in
                        Button(template.name) { applyTemplate(template) }
                    }
                }
            }
            Divider()
            Button("Save current as template…") { templateName = ""; showSave = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "bookmark").font(.system(size: 11))
                Text("Templates").font(.system(size: 11, weight: .medium))
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func applyTemplate(_ template: CloudQueryTemplate) {
        session.query = template.query
        session.rawFilter = template.rawFilter
        session.applyServerQuery()
    }

    private var rawView: some View {
        let filter = CloudFilter.build(
            logName: session.selectedLogName, time: session.timeRange.clause(now: Date()),
            query: session.query, rawFilter: session.rawFilter
        )
        return Text(filter.isEmpty ? "(no filter)" : filter)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LemonadeTheme.spaces.spacing200)
            .background(RoundedRectangle(cornerRadius: 8).fill(LemonadeTheme.colors.background.bgNeutralSubtle))
    }

    // MARK: building blocks

    private func sectionHeader(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            LemonadeUi.Text(title, textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            Spacer()
            trailing()
        }
    }

    private func matchModeMenu(_ binding: Binding<CloudMatchMode>) -> some View {
        Menu {
            ForEach(CloudMatchMode.allCases, id: \.self) { mode in
                Button(mode.label) { binding.wrappedValue = mode }
            }
        } label: {
            Text(binding.wrappedValue.label)
                .font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(width: 110, alignment: .leading)
    }

    private func valueField(_ placeholder: String, _ binding: Binding<String>) -> some View {
        TextField(placeholder, text: binding)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(LemonadeTheme.colors.background.bgNeutralSubtle))
            .frame(maxWidth: 320)
    }

    private func combineToggle(_ binding: Binding<Bool>) -> some View {
        LemonadeUi.Chip(label: binding.wrappedValue ? "OR" : "AND", selected: true,
                        onChipClicked: { binding.wrappedValue.toggle() })
    }

    private func addButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(LemonadeTheme.colors.content.contentBrand)
        }
        .buttonStyle(.plain)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
                .font(.system(size: 13))
                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
        }
        .buttonStyle(.plain)
    }

    private func hint(_ text: String) -> some View {
        LemonadeUi.Text(text, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                        color: LemonadeTheme.colors.content.contentTertiary)
    }
}

/// Label-key picker: lists detected keys with favorites pinned on top; the star toggles favorite
/// (persisted per log name in ~/.jaca), clicking the key selects it.
private struct LabelKeyPicker: View {
    @Bindable var session: CloudLogSession
    @Binding var selectedKey: String
    @State private var show = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// Detected keys (favorites first), narrowed by the search query.
    private var filteredKeys: [String] {
        let all = session.orderedLabelKeys
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Button(action: { query = ""; show = true }) {
            HStack(spacing: 3) {
                Text(selectedKey.isEmpty ? "key…" : selectedKey)
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1)
                    .foregroundStyle(selectedKey.isEmpty
                        ? LemonadeTheme.colors.content.contentTertiary
                        : LemonadeTheme.colors.content.contentPrimary)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 90, alignment: .leading)
        .popover(isPresented: $show, arrowEdge: .bottom) { popover }
    }

    @ViewBuilder private var popover: some View {
        if session.labelKeys.isEmpty {
            LemonadeUi.Text("No labels detected yet — run a session once.",
                            textStyle: LemonadeTypography.shared.bodySmallRegular,
                            color: LemonadeTheme.colors.content.contentTertiary)
                .padding(LemonadeTheme.spaces.spacing400)
                .frame(width: 260)
        } else {
            VStack(spacing: 0) {
                TextField("Search labels…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .padding(LemonadeTheme.spaces.spacing200)
                    .onAppear { DispatchQueue.main.async { searchFocused = true } }
                Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
                let keys = filteredKeys
                if keys.isEmpty {
                    LemonadeUi.Text("No labels match “\(query)”.",
                                    textStyle: LemonadeTypography.shared.bodySmallRegular,
                                    color: LemonadeTheme.colors.content.contentTertiary)
                        .padding(LemonadeTheme.spaces.spacing400)
                        .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(keys, id: \.self) { key in row(key) }
                        }
                    }
                    .frame(height: min(300, CGFloat(keys.count) * 30 + 8))
                }
            }
            .frame(width: 300)
        }
    }

    private func row(_ key: String) -> some View {
        let favorite = session.isFavoriteLabel(key)
        return HStack(spacing: 8) {
            Button(action: { session.toggleFavoriteLabel(key) }) {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(favorite
                        ? LemonadeTheme.colors.content.contentCaution
                        : LemonadeTheme.colors.content.contentTertiary)
            }
            .buttonStyle(.plain)
            .help(favorite ? "Unfavorite" : "Favorite (pin to top)")
            Button(action: { selectedKey = key; show = false }) {
                Text(key)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if key == selectedKey {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LemonadeTheme.colors.content.contentBrand)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(key == selectedKey ? LemonadeTheme.colors.background.bgBrandSubtle : .clear)
    }
}
