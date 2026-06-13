import SwiftUI
import Lemonade

/// Sidebar footer affordance for the in-app updater. Renders nothing unless the
/// feature is enabled and either an update is available or one is in progress.
/// The Update action uses a 2-click confirm because it stashes/switches branches.
struct UpdateBanner: View {
    @State private var update = UpdateModel.shared
    @State private var confirming = false

    var body: some View {
        Group {
            if update.enabled {
                if let phase = update.phase {
                    progressRow(phase)
                } else if case let .available(behind, subject) = update.status {
                    availableRow(behind: behind, subject: subject)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: update.phase)
        .animation(.easeOut(duration: 0.2), value: update.updateAvailable)
    }

    // MARK: - Available

    private func availableRow(behind: Int, subject: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                LemonadeUi.Icon(
                    icon: .sparkles, contentDescription: nil, size: .small,
                    tint: LemonadeTheme.colors.content.contentInfo
                )
                LemonadeUi.Text(
                    "Update available",
                    textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                    color: LemonadeTheme.colors.content.contentPrimary
                )
                Spacer()
                LemonadeUi.Tag(label: "\(behind) behind", voice: .info)
            }
            if !subject.isEmpty {
                LemonadeUi.Text(
                    subject,
                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                    color: LemonadeTheme.colors.content.contentSecondary,
                    maxLines: 1
                )
            }
            LemonadeUi.Button(
                label: confirming ? "Pull main & reinstall?" : "Update",
                onClick: { handleTap() },
                leadingIcon: .download,
                variant: .primary,
                type: confirming ? .solid : .subtle,
                size: .xSmall
            )
            .fixedSize()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    // MARK: - In progress / failed

    @ViewBuilder private func progressRow(_ phase: UpdatePhase) -> some View {
        let failed = { if case .failed = phase { return true } else { return false } }()
        HStack(spacing: 8) {
            if failed {
                LemonadeUi.Icon(
                    icon: .circleX, contentDescription: nil, size: .small,
                    tint: LemonadeTheme.colors.content.contentCritical
                )
            } else {
                ProgressView().controlSize(.small)
            }
            LemonadeUi.Text(
                phase.label,
                textStyle: LemonadeTypography.shared.bodySmallRegular,
                color: failed
                    ? LemonadeTheme.colors.content.contentCritical
                    : LemonadeTheme.colors.content.contentSecondary,
                maxLines: 2
            )
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
    }

    // MARK: - Action (two-click confirm)

    private func handleTap() {
        if confirming {
            confirming = false
            update.runUpdate()
        } else {
            confirming = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                confirming = false
            }
        }
    }
}
