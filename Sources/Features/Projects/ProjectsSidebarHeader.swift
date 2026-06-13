import SwiftUI
import Lemonade

/// Sidebar section header for Projects, styled to match the other area headers. Tapping
/// it navigates to the Projects area; the `+` adds a project folder and the refresh icon
/// rescans. Highlights when active.
struct ProjectsSidebarHeader: View {
    @Bindable var model: AppModel

    private var active: Bool { model.mode == .projects }

    var body: some View {
        HStack(spacing: 6) {
            LemonadeUi.Text(
                "Projects",
                textStyle: LemonadeTypography.shared.headingXSmall,
                color: active
                    ? LemonadeTheme.colors.content.contentPrimary
                    : LemonadeTheme.colors.content.contentSecondary
            )
            Spacer()
            Button(action: { model.projects.addFolder() }) {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
            }
            .buttonStyle(.plain)
            .help("Add a project folder")
            .accessibilityIdentifier("projectsAddFolderButton")

            Button(action: { model.projects.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
            }
            .buttonStyle(.plain)
            .help("Rescan projects")
            .accessibilityIdentifier("projectsRefreshButton")
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing200)
        .padding(.vertical, LemonadeTheme.spaces.spacing100)
        .background(
            RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                .fill(active ? LemonadeTheme.colors.interaction.bgSubtleInteractive : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.mode = .projects }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.top, LemonadeTheme.spaces.spacing300)
        .accessibilityIdentifier("projectsHeader")
    }
}
