import SwiftUI
import Lemonade

/// Sidebar section header for Worktrees, styled to match the "Devices" header
/// (title + trailing icon). Tapping it navigates the main area to the worktrees
/// view; the folder+ icon picks/changes the worktrees folder. Highlights when active.
struct WorktreesSidebarHeader: View {
    @Bindable var model: AppModel

    private var active: Bool { model.mode == .worktrees }

    var body: some View {
        HStack {
            LemonadeUi.Text(
                "Worktrees",
                textStyle: LemonadeTypography.shared.headingXSmall,
                color: active
                    ? LemonadeTheme.colors.content.contentPrimary
                    : LemonadeTheme.colors.content.contentSecondary
            )
            Spacer()
            Button(action: pickFolder) {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
            }
            .buttonStyle(.plain)
            .help("Choose worktrees folder")
            .accessibilityIdentifier("worktreesFolderButton")
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing200)
        .padding(.vertical, LemonadeTheme.spaces.spacing150)
        .background(
            RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                .fill(active ? LemonadeTheme.colors.interaction.bgSubtleInteractive : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.mode = .worktrees }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.top, LemonadeTheme.spaces.spacing300)
        .accessibilityIdentifier("worktreesHeader")
    }

    private func pickFolder() {
        if let url = WorktreesOpen.pickFolder() {
            model.worktrees.selectFolder(url)
            model.mode = .worktrees
        }
    }
}
