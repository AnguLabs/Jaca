import SwiftUI
import Lemonade

/// The "WORKTREES" overline that introduces the list, with an orphan count pinned to
/// the trailing edge. Authored against semantic Lemonade tokens so it adapts to the
/// app's color scheme.
struct SectionLabel: View {
    let tab: WorktreesTab

    var body: some View {
        HStack(spacing: 0) {
            LemonadeUi.Text(
                "WORKTREES",
                textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                color: LemonadeTheme.colors.content.contentTertiary
            )

            Spacer()

            LemonadeUi.Text(
                "\(tab.orphanCount) orphaned",
                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                color: LemonadeTheme.colors.content.contentSecondary
            )
        }
        .padding(.top, 9)
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }
}
