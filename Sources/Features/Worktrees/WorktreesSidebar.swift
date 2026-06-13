import SwiftUI
import Lemonade

/// Minimal sidebar content for the Worktrees mode: just shows the current folder (or a
/// hint when none is selected). The actual worktree list lives in the main pane
/// (`WorktreesAreaView`).
struct WorktreesSidebar: View {
    let model: WorktreesModel

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
            if model.folder == nil {
                LemonadeUi.Text(
                    "No folder selected",
                    textStyle: LemonadeTypography.shared.bodySmallRegular,
                    color: LemonadeTheme.colors.content.contentSecondary
                )
                LemonadeUi.Text(
                    "Choose a folder in the main view to manage its worktrees.",
                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                    color: LemonadeTheme.colors.content.contentTertiary
                )
            } else {
                LemonadeUi.Text(
                    "FOLDER",
                    textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                    color: LemonadeTheme.colors.content.contentTertiary
                )
                HStack(spacing: LemonadeTheme.spaces.spacing200) {
                    GroveIcon(
                        glyph: .folder,
                        size: 16,
                        tint: LemonadeTheme.colors.content.contentBrand
                    )
                    LemonadeUi.Text(
                        model.folder?.lastPathComponent ?? "",
                        textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                        color: LemonadeTheme.colors.content.contentPrimary,
                        maxLines: 1
                    )
                }
                LemonadeUi.Text(
                    model.displayFolderPath,
                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                    color: LemonadeTheme.colors.content.contentTertiary,
                    maxLines: 2
                )
            }
            Spacer(minLength: 0)
        }
        .padding(LemonadeTheme.spaces.spacing300)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LemonadeTheme.colors.background.bgElevated)
    }
}
