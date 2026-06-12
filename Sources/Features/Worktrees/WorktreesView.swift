import SwiftUI
import Lemonade

/// The detail content for a worktrees tab. Unlike the menu-bar panel it was ported from,
/// this fills its pane (no fixed width, no frosted/blur/shadow chrome) and adapts to the
/// app's color scheme via semantic Lemonade tokens.
struct WorktreesView: View {
    let tab: WorktreesTab

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LemonadeTheme.colors.background.bgDefault)
            .overlay(alignment: .bottom) {
                if let toast = tab.toast {
                    WorktreeToastView(toast: toast)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.2), value: tab.toast)
            .onAppear { tab.refreshOnOpen() }
    }

    @ViewBuilder private var content: some View {
        switch tab.phase {
        case .empty:
            emptyState
        case .scanning:
            scanningState
        case .ready:
            readyState
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        LemonadeUi.Text(
            "No worktrees found in \(tab.displayName)",
            textStyle: LemonadeTypography.shared.bodyMediumRegular,
            textAlign: .center,
            color: LemonadeTheme.colors.content.contentSecondary
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Scanning

    private var scanningState: some View {
        VStack(spacing: 12) {
            LemonadeUi.Spinner()
            LemonadeUi.Text(
                "Scanning…",
                textStyle: LemonadeTypography.shared.bodyMediumRegular,
                color: LemonadeTheme.colors.content.contentSecondary
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ready

    private var readyState: some View {
        VStack(spacing: 0) {
            FolderBar(tab: tab)
            SectionLabel(tab: tab)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(tab.trees) { w in
                        WorktreeRow(
                            w: w,
                            isOpen: tab.openId == w.id,
                            tab: tab,
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.2)) { tab.toggle(w.id) }
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: .infinity)
        }
    }
}
