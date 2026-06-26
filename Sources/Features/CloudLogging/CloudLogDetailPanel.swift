import SwiftUI
import Lemonade
import AppKit

/// Right-side detail panel for a selected entry (req 11). Shows every field EXCEPT the
/// textPayload (that's already the row's message). All values are selectable text, so anything
/// can be copied manually; a right-click context menu (and a hover button on labels) adds the
/// quick-filter actions — Copy / "Filter by this value" / "Add this value (OR)" — which mutate
/// the session's structured query and restart the poll (req 12).
struct CloudLogDetailPanel: View {
    @Bindable var session: CloudLogSession
    let entry: CloudLogEntry
    /// Opens a NEW session pre-filtered by a clicked value (current session stays put).
    var onNewSession: (CloudSessionFork) -> Void = { _ in }
    @State private var showRaw = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
                    messageSection      // selectable — so any portion of the log text can be copied
                    severityField
                    field("TIME", entry.timestamp.formatted(date: .abbreviated, time: .standard))
                    if let received = entry.receiveTimestamp {
                        field("RECEIVED", received.formatted(date: .omitted, time: .standard))
                    }
                    field("LOG", entry.logId)
                    if !entry.resourceType.isEmpty { field("RESOURCE TYPE", entry.resourceType) }
                    labelsSection("LABELS", entry.labels, scope: .entry)
                    labelsSection("RESOURCE LABELS", entry.resourceLabels, scope: .resource)
                    if let http = entry.httpRequestSummary { field("HTTP REQUEST", http) }
                    if let trace = entry.trace { field("TRACE", trace) }
                    if let span = entry.spanId { field("SPAN", span) }
                    if !entry.insertId.isEmpty { field("INSERT ID", entry.insertId) }
                    rawSection
                }
                .padding(LemonadeTheme.spaces.spacing300)
            }
        }
        .background(LemonadeTheme.colors.background.bgElevated)
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            LemonadeUi.Text("DETAILS", textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            Spacer()
            LemonadeUi.IconButton(icon: .copy, contentDescription: "Copy JSON",
                                  onClick: { copy(entry.raw) }, size: .small)
            Button(action: { session.selectedEntry = nil }) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(10)
    }

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                overline("MESSAGE")
                Spacer()
                LemonadeUi.IconButton(icon: .copy, contentDescription: "Copy message",
                                      onClick: { copy(entry.message) }, size: .small)
            }
            Text(entry.message.isEmpty ? "—" : entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                .textSelection(.enabled)     // select any portion to copy
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LemonadeTheme.spaces.spacing200)
                .background(RoundedRectangle(cornerRadius: 8).fill(LemonadeTheme.colors.background.bgNeutralSubtle))
                .contextMenu { Button("Copy") { copy(entry.message) } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var severityField: some View {
        VStack(alignment: .leading, spacing: 4) {
            overline("SEVERITY")
            Text(entry.severity.apiName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(CloudSeverityStyle.color(for: entry.severity))
                .textSelection(.enabled)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(CloudSeverityStyle.badgeBackground(for: entry.severity)))
                .contextMenu {
                    Button("Copy") { copy(entry.severity.apiName) }
                    Button("Filter by \(entry.severity.name)") { session.filterBySeverity(entry.severity) }
                    Button("Open in new session (\(entry.severity.name))") {
                        onNewSession(session.forkAddingSeverity(entry.severity))
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func labelsSection(_ title: String, _ labels: [String: String], scope: LabelScope) -> some View {
        if !labels.isEmpty {
            let sorted = labels.sorted { $0.key < $1.key }
            VStack(alignment: .leading, spacing: 6) {
                overline(title)
                VStack(spacing: 0) {
                    ForEach(Array(sorted.enumerated()), id: \.element.key) { index, pair in
                        LabelRow(
                            key: pair.key, value: pair.value,
                            onFilter: { session.filterByLabel(scope: scope, key: pair.key, value: pair.value) },
                            onOr: { session.orLabel(scope: scope, key: pair.key, value: pair.value) },
                            onCopy: copy,
                            onNewSession: { onNewSession(session.forkAddingLabel(scope: scope, key: pair.key, value: pair.value)) }
                        )
                        if index < sorted.count - 1 {
                            Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(LemonadeTheme.colors.border.borderNeutralLow, lineWidth: 1))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rawSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { showRaw.toggle() }) {
                HStack(spacing: 5) {
                    Image(systemName: showRaw ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    overline("RAW JSON")
                }
            }
            .buttonStyle(.plain)
            if showRaw {
                Text(entry.raw)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LemonadeTheme.spaces.spacing200)
                    .background(RoundedRectangle(cornerRadius: 8).fill(LemonadeTheme.colors.background.bgNeutralSubtle))
                    .contextMenu { Button("Copy JSON") { copy(entry.raw) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: building blocks

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            overline(label)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu { Button("Copy") { copy(value) } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func overline(_ text: String) -> some View {
        LemonadeUi.Text(text, textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                        color: LemonadeTheme.colors.content.contentTertiary)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One key/value row inside the styled labels container. The key and value are both selectable
/// text (manual copy), a filter funnel appears on hover for a one-click "filter by this value",
/// and the right-click menu carries the full set of actions.
private struct LabelRow: View {
    let key: String
    let value: String
    var onFilter: () -> Void
    var onOr: () -> Void
    var onCopy: (String) -> Void
    var onNewSession: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                .textSelection(.enabled)
                .frame(width: 140, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 7) {
                Button(action: onFilter) {
                    Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 12))
                }
                .buttonStyle(.plain).help("Filter this session by this value")
                Button(action: onNewSession) {
                    Image(systemName: "plus.rectangle.on.rectangle").font(.system(size: 11))
                }
                .buttonStyle(.plain).help("Open a new session filtered by this value")
            }
            .foregroundStyle(LemonadeTheme.colors.content.contentBrand)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(hovering ? LemonadeTheme.colors.interaction.bgSubtleInteractive : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Copy value") { onCopy(value) }
            Button("Copy “\(key)=\(value)”") { onCopy("\(key)=\(value)") }
            Divider()
            Button("Filter by this value") { onFilter() }
            Button("Add this value (OR)") { onOr() }
            Button("Open in new session") { onNewSession() }
        }
    }
}
