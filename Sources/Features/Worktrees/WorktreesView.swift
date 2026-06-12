import SwiftUI
import Lemonade

struct WorktreesView: View {
    let tab: WorktreesTab
    var body: some View {
        LemonadeUi.Text("Worktrees: \(tab.displayName) — \(tab.trees.count) found",
                        textStyle: LemonadeTypography.shared.bodyMediumRegular,
                        color: LemonadeTheme.colors.content.contentPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LemonadeTheme.colors.background.bgDefault)
    }
}
