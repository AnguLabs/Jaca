import SwiftUI
import Lemonade
import AppKit

/// A small floating "gcloud" button (bottom-right of the Cloud Logging area) that opens the
/// debug console — every gcloud command Jaca ran, with exit code, stderr and output — so when a
/// query fails you can see exactly what was sent.
struct GcloudDebugButton: View {
    /// Compact = an inline status-bar button (no capsule/shadow); otherwise a floating pill.
    var compact: Bool = false
    @State private var show = false
    @State private var hovering = false

    var body: some View {
        Button(action: { show = true }) {
            label
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show the raw gcloud CLI commands + output (debug)")
        .accessibilityIdentifier("gcloudDebugButton")
        .sheet(isPresented: $show) { GcloudDebugConsoleView() }
    }

    @ViewBuilder private var label: some View {
        if compact {
            HStack(spacing: 4) {
                Image(systemName: "terminal").font(.system(size: 10, weight: .semibold))
                Text("gcloud").font(.system(size: 11))
            }
            .foregroundStyle(hovering
                ? LemonadeTheme.colors.content.contentBrand
                : LemonadeTheme.colors.content.contentSecondary)
        } else {
            HStack(spacing: 5) {
                Image(systemName: "terminal").font(.system(size: 11, weight: .semibold))
                Text("gcloud").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(LemonadeTheme.colors.background.bgElevated))
            .overlay(Capsule().strokeBorder(LemonadeTheme.colors.border.borderNeutralLow, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
    }
}

/// Lists recent gcloud invocations (newest first), refreshing while open.
struct GcloudDebugConsoleView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [GcloudDebugEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            DebugRow(entry: entry)
                            Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(width: 780, height: 580)
        .background(LemonadeTheme.colors.background.bgDefault)
        .task {
            while !Task.isCancelled {
                entries = GcloudDebugLog.shared.snapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            LemonadeUi.Text("gcloud debug console",
                            textStyle: LemonadeTypography.shared.headingSmall,
                            color: LemonadeTheme.colors.content.contentPrimary)
            LemonadeUi.Text("\(entries.count) commands",
                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            color: LemonadeTheme.colors.content.contentTertiary)
            Spacer()
            LemonadeUi.Button(label: "Copy all", onClick: { copyAll() }, leadingIcon: .copy,
                              variant: .neutral, type: .subtle, size: .small).fixedSize()
            LemonadeUi.Button(label: "Clear", onClick: { GcloudDebugLog.shared.clear(); entries = [] },
                              leadingIcon: .trash, variant: .neutral, type: .subtle, size: .small).fixedSize()
            LemonadeUi.Button(label: "Done", onClick: { dismiss() },
                              variant: .neutral, type: .subtle, size: .small).fixedSize()
        }
        .padding(LemonadeTheme.spaces.spacing300)
    }

    private var emptyState: some View {
        LemonadeUi.Text("No gcloud commands yet. Start a session or refresh log names, then check back.",
                        textStyle: LemonadeTypography.shared.bodyMediumRegular, textAlign: .center,
                        color: LemonadeTheme.colors.content.contentSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private func copyAll() {
        let text = entries.map { entry -> String in
            var parts = ["$ \(entry.command)", "exit \(entry.exitCode) · \(entry.durationMs)ms"]
            if !entry.stderr.isEmpty { parts.append("stderr:\n\(entry.stderr)") }
            return parts.joined(separator: "\n")
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One command row: status + timing + the command, and (expandable) stderr/stdout. Everything
/// selectable so it can be copied manually.
private struct DebugRow: View {
    let entry: GcloudDebugEntry
    @State private var showOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(entry.ok ? "exit 0" : "exit \(entry.exitCode)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(entry.ok ? LemonadeTheme.colors.content.contentPositive
                                     : LemonadeTheme.colors.content.contentCritical)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(entry.ok
                        ? LemonadeTheme.colors.background.bgNeutralSubtle
                        : LemonadeTheme.colors.background.bgCriticalSubtle))
                Text(entry.date.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                Text("\(entry.durationMs)ms")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                Spacer()
                if !entry.stdoutPreview.isEmpty {
                    Button(action: { showOutput.toggle() }) {
                        Text(showOutput ? "hide output" : "output")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(LemonadeTheme.colors.content.contentBrand)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(entry.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !entry.stderr.isEmpty {
                Text(entry.stderr)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentCritical)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showOutput {
                Text(entry.stdoutPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LemonadeTheme.spaces.spacing200)
                    .background(RoundedRectangle(cornerRadius: 6).fill(LemonadeTheme.colors.background.bgNeutralSubtle))
            }
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing200)
    }
}
