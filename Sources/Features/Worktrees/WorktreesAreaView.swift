import SwiftUI
import Lemonade

/// The main-pane content for the Worktrees top-level mode. When no folder is selected it
/// shows a centered empty state with a "Choose folder…" affordance; once a folder is
/// picked it shows the folder bar (with a change-folder button), the section label, and
/// the scrollable worktree list. Fills its pane and adapts to the app's color scheme via
/// semantic Lemonade tokens.
struct WorktreesAreaView: View {
    let model: WorktreesModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LemonadeTheme.colors.background.bgDefault)
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    WorktreeToastView(toast: toast)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.toast)
            .onAppear { model.refreshOnOpen() }
    }

    @ViewBuilder private var content: some View {
        if model.folder == nil {
            noFolderState
        } else {
            switch model.phase {
            case .empty:
                folderHeaderWrapped { emptyState }
            case .scanning:
                folderHeaderWrapped { scanningState }
            case .ready:
                readyState
            }
        }
    }

    /// Wraps a sub-state (empty/scanning) with the folder bar on top so the change-folder
    /// affordance is always reachable once a folder has been chosen.
    @ViewBuilder private func folderHeaderWrapped<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        VStack(spacing: 0) {
            FolderBar(model: model, onChangeFolder: changeFolder)
            inner()
        }
    }

    private func changeFolder() {
        if let url = WorktreesOpen.pickFolder() { model.selectFolder(url) }
    }

    // MARK: - No folder selected

    private var noFolderState: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing300) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LemonadeTheme.colors.background.bgBrandSubtle)
                .frame(width: 64, height: 64)
                .overlay(
                    GroveIcon(
                        glyph: .folder,
                        size: 32,
                        tint: LemonadeTheme.colors.content.contentBrand
                    )
                )
            LemonadeUi.Text(
                "No worktrees folder selected",
                textStyle: LemonadeTypography.shared.headingSmall,
                color: LemonadeTheme.colors.content.contentPrimary
            )
            LemonadeUi.Text(
                "Choose a folder that holds git worktrees to manage their disk usage.",
                textStyle: LemonadeTypography.shared.bodyMediumRegular,
                textAlign: .center,
                color: LemonadeTheme.colors.content.contentSecondary
            )
            LemonadeUi.Button(
                label: "Choose folder…",
                onClick: changeFolder,
                leadingIcon: .plus,
                variant: .primary,
                type: .solid,
                size: .medium
            )
            .fixedSize()   // hug the label instead of stretching full-width
            .padding(.top, LemonadeTheme.spaces.spacing200)
        }
        .padding(LemonadeTheme.spaces.spacing800)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("worktreesEmptyState")
    }

    // MARK: - Empty (folder selected, no worktrees)

    private var emptyState: some View {
        LemonadeUi.Text(
            "No worktrees found in \(model.displayFolderPath)",
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
            FolderBar(model: model, onChangeFolder: changeFolder)
            SectionLabel(model: model)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(model.trees) { w in
                        WorktreeRow(
                            w: w,
                            isOpen: model.openId == w.id,
                            model: model,
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.2)) { model.toggle(w.id) }
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
