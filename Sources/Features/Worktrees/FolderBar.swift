import SwiftUI
import Lemonade

/// The rounded "fill" row at the top of the ready list: a folder badge and the bound
/// folder path (monospaced, middle-truncated) with a worktree/size summary beneath it.
/// A worktrees tab is bound to one folder, so there's no "Change" affordance — switching
/// folders means opening another tab. Authored against semantic Lemonade tokens.
struct FolderBar: View {
    let tab: WorktreesTab

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LemonadeTheme.colors.background.bgBrandSubtle)
                .frame(width: 30, height: 30)
                .overlay(
                    GroveIcon(
                        glyph: .folder,
                        size: 17,
                        tint: LemonadeTheme.colors.content.contentBrand
                    )
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(tab.displayFolderPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                LemonadeUi.Text(
                    "\(tab.trees.count) worktrees · \(formatSize(tab.total)) on disk",
                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                    color: LemonadeTheme.colors.content.contentSecondary
                )
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
        )
        .padding(.top, 8)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}
