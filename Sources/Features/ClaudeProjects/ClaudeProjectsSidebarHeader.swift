import SwiftUI
import Lemonade

/// Sidebar section header for Claude Projects, styled to match the other area headers.
/// Tapping it navigates the main area to the Claude Projects view; the refresh icon
/// rescans `~/.claude/projects`. Highlights when active.
struct ClaudeProjectsSidebarHeader: View {
    @Bindable var model: AppModel

    private var active: Bool { model.mode == .claudeProjects }

    var body: some View {
        HStack {
            LemonadeUi.Text(
                "Claude Projects",
                textStyle: LemonadeTypography.shared.headingXSmall,
                color: active
                    ? LemonadeTheme.colors.content.contentPrimary
                    : LemonadeTheme.colors.content.contentSecondary
            )
            Spacer()
            Button(action: { model.claudeProjects.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
            }
            .buttonStyle(.plain)
            .help("Rescan Claude projects")
            .accessibilityIdentifier("claudeProjectsRefreshButton")
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing200)
        .padding(.vertical, LemonadeTheme.spaces.spacing100)
        .background(
            RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                .fill(active ? LemonadeTheme.colors.interaction.bgSubtleInteractive : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.mode = .claudeProjects }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.top, LemonadeTheme.spaces.spacing300)
        .accessibilityIdentifier("claudeProjectsHeader")
    }
}
