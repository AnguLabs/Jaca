import SwiftUI
import Lemonade

/// The main-pane content for the Claude Projects top-level mode: every project Claude
/// Code has run in, each showing its real folder and an expandable list of detected
/// worktrees. Mirrors `XcodeAreaView`'s structure (header card + scrollable list).
///
/// Renders cached results immediately and only rescans when the data is stale. While a
/// scan runs with cached data on screen, a "Refreshing…" banner shows and the list is
/// blocked from interaction until it completes.
struct ClaudeProjectsAreaView: View {
    let model: ClaudeProjectsModel

    private var blockingRefresh: Bool { model.isRefreshing && !model.hasNoData }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LemonadeTheme.colors.background.bgDefault)
            .onAppear { if model.shouldAutoRefresh { model.refresh() } }
            .accessibilityIdentifier("claudeProjectsArea")
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            header
            if blockingRefresh { refreshingBanner }
            listSection
                .allowsHitTesting(!blockingRefresh)
                .opacity(blockingRefresh ? 0.55 : 1)
                .animation(.easeInOut(duration: 0.15), value: blockingRefresh)
        }
    }

    /// "CLAUDE PROJECTS" overline + project / worktree counts, with an inline spinner
    /// while refreshing.
    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                LemonadeUi.Text(
                    "CLAUDE PROJECTS",
                    textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                    color: LemonadeTheme.colors.content.contentTertiary
                )
                LemonadeUi.Text(
                    "\(model.projects.count) projects · \(model.totalWorktrees) worktrees",
                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                    color: LemonadeTheme.colors.content.contentSecondary
                )
            }
            Spacer()
            if model.isRefreshing { LemonadeUi.Spinner() }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
        )
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    /// A thin banner shown over cached results while a fresh scan runs.
    private var refreshingBanner: some View {
        HStack(spacing: 8) {
            LemonadeUi.Spinner()
            LemonadeUi.Text(
                "Refreshing… showing cached results",
                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                color: LemonadeTheme.colors.content.contentSecondary
            )
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LemonadeTheme.colors.background.bgBrandSubtle)
        )
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .transition(.opacity)
        .accessibilityIdentifier("claudeProjectsRefreshingBanner")
    }

    @ViewBuilder private var listSection: some View {
        if model.hasNoData {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(model.projects) { project in
                        ClaudeProjectRow(
                            project: project,
                            isExpanded: model.isExpanded(project.id),
                            model: model,
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.2)) { model.toggle(project.id) }
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        LemonadeUi.Text(
            model.isRefreshing ? "Scanning ~/.claude/projects…" : "No Claude projects found",
            textStyle: LemonadeTypography.shared.bodyMediumRegular,
            textAlign: .center,
            color: LemonadeTheme.colors.content.contentSecondary
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityIdentifier("claudeProjectsEmptyState")
    }
}
