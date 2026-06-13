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
            .onAppear { model.startPolling() }
            .onDisappear { model.stopPolling() }
    }

    @ViewBuilder private var content: some View {
        if model.daemons.isEmpty {
            emptyState
        } else {
            readyState
        }
    }

    private var emptyState: some View {
        LemonadeUi.Text(
            "No Gradle daemons running",
            textStyle: LemonadeTypography.shared.bodyMediumRegular,
            textAlign: .center,
            color: LemonadeTheme.colors.content.contentSecondary
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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
                LemonadeUi.Tag(label: daemon.version, voice: .neutral)
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
