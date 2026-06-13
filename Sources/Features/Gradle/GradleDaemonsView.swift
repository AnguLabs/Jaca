import SwiftUI
import Lemonade

/// The main-pane content for the Gradle top-level mode: a live, polled list of
/// running Gradle daemons with kill/uptime/%CPU/RAM. Mirrors `WorktreesAreaView`'s
/// structure (empty state, scrollable list, bottom-center toast). Polls while visible.
struct GradleDaemonsView: View {
    let model: GradleDaemonsModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LemonadeTheme.colors.background.bgDefault)
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    GradleToastView(toast: toast)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.toast)
            .onAppear { model.startPolling(); model.refreshCache() }
            .onDisappear { model.stopPolling() }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            // The cache lives on disk regardless of running daemons, so it always shows
            // (with a "Calculating…" state while `du` runs on first open).
            if model.cacheLoading || !model.cacheEntries.isEmpty { cacheSection }
            daemonsSection
        }
    }

    /// Size of `~/.gradle/caches` broken down per Gradle version, shown above the daemon list.
    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                LemonadeUi.Text(
                    "GRADLE CACHE",
                    textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                    color: LemonadeTheme.colors.content.contentTertiary
                )
                Spacer()
                LemonadeUi.Text(
                    model.cacheEntries.isEmpty ? "Calculating…" : "\(formatSize(model.cacheTotalMB)) total",
                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                    color: LemonadeTheme.colors.content.contentSecondary
                )
            }
            if model.cacheEntries.isEmpty && model.cacheLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    LemonadeUi.Text(
                        "Measuring cache size…",
                        textStyle: LemonadeTypography.shared.bodySmallRegular,
                        color: LemonadeTheme.colors.content.contentSecondary
                    )
                }
                .padding(.vertical, 4)
            } else {
                // Versions side by side (wraps to new lines when there are many).
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(model.cacheEntries) { entry in
                        GradleCacheCard(entry: entry, model: model)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
        )
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    @ViewBuilder private var daemonsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            LemonadeUi.Text(
                "DAEMONS",
                textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                color: LemonadeTheme.colors.content.contentTertiary
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if model.daemons.isEmpty {
                emptyState
            } else {
                readyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        LemonadeUi.Text(
            "No Gradle daemons running",
            textStyle: LemonadeTypography.shared.bodyMediumRegular,
            color: LemonadeTheme.colors.content.contentSecondary
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .accessibilityIdentifier("gradleEmptyState")
    }

    private var readyState: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(model.daemons) { daemon in
                    GradleDaemonRow(daemon: daemon, model: model)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity)
    }
}

/// A compact card for one Gradle version's cache: version, size, and a 2-click-confirm Delete.
private struct GradleCacheCard: View {
    let entry: GradleCacheEntry
    let model: GradleDaemonsModel
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LemonadeUi.Text(
                entry.version,
                textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                color: LemonadeTheme.colors.content.contentPrimary
            )
            Text(formatSize(entry.sizeMB))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
            LemonadeUi.Button(
                label: confirming ? "Confirm?" : "Delete",
                onClick: { handleTap() },
                leadingIcon: .trash,
                variant: .critical,
                type: confirming ? .solid : .subtle,
                size: .xSmall
            )
            .fixedSize()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LemonadeTheme.colors.background.bgDefault)
        )
    }

    private func handleTap() {
        if confirming {
            confirming = false
            model.deleteCache(entry.version)
        } else {
            confirming = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                confirming = false
            }
        }
    }
}

/// One row per Gradle daemon: an avatar, "Gradle <version>" with the PID as subtitle,
/// version + RAM tags, uptime/%CPU mono text, and a two-click-confirm Kill button.
struct GradleDaemonRow: View {
    let daemon: GradleDaemon
    let model: GradleDaemonsModel
    @State private var confirmingKill = false

    var body: some View {
        HStack(spacing: 11) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                LemonadeUi.Text(
                    "Gradle \(daemon.version)",
                    textStyle: LemonadeTypography.shared.bodyMediumSemiBold,
                    color: LemonadeTheme.colors.content.contentPrimary,
                    maxLines: 1
                )
                LemonadeUi.Text(
                    "PID \(daemon.pid)",
                    textStyle: LemonadeTypography.shared.bodySmallRegular,
                    color: LemonadeTheme.colors.content.contentSecondary,
                    maxLines: 1
                )
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                LemonadeUi.Tag(label: daemon.isBusy ? "BUSY" : "IDLE",
                               voice: daemon.isBusy ? .positive : .neutral)
                if let jdk = daemon.jdk {
                    LemonadeUi.Tag(label: "JDK \(jdk)", voice: .neutral)
                }
                if let heap = daemon.maxHeap {
                    LemonadeUi.Tag(label: heap, voice: .neutral)
                }
                LemonadeUi.Tag(label: ramText, voice: .neutral)
            }

            VStack(alignment: .trailing, spacing: 3) {
                Text(daemon.uptime)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                Text(cpuText)
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
            }

            LemonadeUi.Button(
                label: confirmingKill ? "Confirm kill?" : "Kill",
                onClick: { handleKillTap() },
                leadingIcon: .circleX,
                variant: .critical,
                type: confirmingKill ? .solid : .subtle,
                size: .xSmall
            )
            .fixedSize()
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.clear)
        )
        .contentShape(Rectangle())
        .opacity(daemon.removing ? 0 : 1)
        .animation(.easeInOut(duration: 0.28), value: daemon.removing)
    }

    // MARK: - Avatar

    private var avatar: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
            .frame(width: 34, height: 34)
            .overlay(
                LemonadeUi.Icon(
                    icon: .bug,
                    contentDescription: nil,
                    size: .small,
                    tint: LemonadeTheme.colors.content.contentPrimary
                )
            )
    }

    // MARK: - Formatting

    private var ramText: String {
        if daemon.memoryMB >= 1024 {
            return String(format: "%.1f GB", Double(daemon.memoryMB) / 1024)
        }
        return "\(daemon.memoryMB) MB"
    }

    private var cpuText: String {
        "\(Int(daemon.cpu.rounded()))%"
    }

    // MARK: - Kill (two-click confirm)

    private func handleKillTap() {
        if confirmingKill {
            confirmingKill = false
            model.kill(daemon.pid)
        } else {
            confirmingKill = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                confirmingKill = false
            }
        }
    }
}
