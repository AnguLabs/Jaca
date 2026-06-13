import SwiftUI
import Lemonade

/// Sidebar section header for Gradle, styled to match the "Worktrees" header.
/// Tapping it navigates the main area to the Gradle daemons view; a small refresh
/// icon re-lists the daemons. Highlights when active.
struct GradleSidebarHeader: View {
    @Bindable var model: AppModel

    private var active: Bool { model.mode == .gradle }

    var body: some View {
        HStack {
            LemonadeUi.Text(
                "Gradle",
                textStyle: LemonadeTypography.shared.headingXSmall,
                color: active
                    ? LemonadeTheme.colors.content.contentPrimary
                    : LemonadeTheme.colors.content.contentSecondary
            )
            Spacer()
            Button(action: { model.gradle.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
            }
            .buttonStyle(.plain)
            .help("Refresh Gradle daemons")
            .accessibilityIdentifier("gradleRefreshButton")
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing200)
        .padding(.vertical, LemonadeTheme.spaces.spacing100)
        .background(
            RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                .fill(active ? LemonadeTheme.colors.interaction.bgSubtleInteractive : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.mode = .gradle }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.top, LemonadeTheme.spaces.spacing200)
        .accessibilityIdentifier("gradleHeader")
    }
}
