import SwiftUI
import Lemonade

/// The main-pane content for the Projects area: every project Claude Code has run in
/// (plus any folders the user added), each expandable to its checkouts (main + worktrees)
/// with per-checkout cache cleanup and worktree removal.
///
/// First cold scan (no cache) shows a blocking loader; afterwards cached results render
/// immediately and refreshes run in the background behind a subtle "Refreshing…" pill.
struct ProjectsAreaView: View {
    let model: ProjectsModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LemonadeTheme.colors.background.bgDefault)
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    ProjectsToastView(toast: toast)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.toast)
            .onAppear { if model.shouldAutoRefresh { model.refresh() } }
            .sheet(isPresented: Binding(
                get: { model.showingHerdrConfig },
                set: { model.showingHerdrConfig = $0 }
            )) {
                HerdrConfigSheet(model: model)
            }
            .sheet(isPresented: Binding(
                get: { model.showingHerdrLaunch },
                set: { model.showingHerdrLaunch = $0 }
            )) {
                HerdrLaunchSheet(model: model)
            }
            .accessibilityIdentifier("projectsArea")
    }

    @ViewBuilder private var content: some View {
        if model.isFirstLoad {
            firstLoadState
        } else if model.hasNoData {
            emptyState
        } else {
            VStack(spacing: 0) {
                header
                sizeScanBar
                listSection
            }
        }
    }

    /// "PROJECTS" overline + counts, the LIST/TREE toggle, and an inline "Refreshing…"
    /// pill during background scans.
    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                LemonadeUi.Text(
                    "PROJECTS",
                    textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                    color: LemonadeTheme.colors.content.contentTertiary
                )
                LemonadeUi.Text(
                    "\(model.totalProjects) projects · \(model.totalWorktrees) worktrees",
                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                    color: LemonadeTheme.colors.content.contentSecondary
                )
            }
            Spacer()
            if model.isRefreshing {
                HStack(spacing: 6) {
                    LemonadeUi.Spinner()
                    LemonadeUi.Text(
                        "Refreshing…",
                        textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                        color: LemonadeTheme.colors.content.contentSecondary
                    )
                }
                .transition(.opacity)
            }
            if model.herdrInstalled { herdrSettingsButton }
            viewModePicker
        }
        .animation(.easeInOut(duration: 0.15), value: model.isRefreshing)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
        )
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    /// Asks before walking every checkout for its size, then reports progress while it
    /// runs. The answer lives for this launch only — a relaunch asks again.
    @ViewBuilder private var sizeScanBar: some View {
        Group {
            if model.needsSizeApproval {
                sizeScanRow {
                    LemonadeUi.Button(
                        label: "Not now", onClick: { model.declineSizeScan() },
                        variant: .neutral, type: .subtle, size: .small
                    )
                    LemonadeUi.Button(
                        label: "Calculate", onClick: { withAnimation(.easeInOut(duration: 0.2)) { model.approveSizeScan() } },
                        variant: .primary, type: .solid, size: .small
                    )
                }
            } else if model.isComputingSizes {
                sizeScanRow {
                    LemonadeUi.Spinner()
                    LemonadeUi.Button(
                        label: "Stop", onClick: { withAnimation(.easeInOut(duration: 0.2)) { model.cancelSizeScan() } },
                        variant: .neutral, type: .subtle, size: .small
                    )
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.needsSizeApproval)
        .animation(.easeInOut(duration: 0.2), value: model.isComputingSizes)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func sizeScanRow<Actions: View>(@ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            GroveIcon(glyph: .folder, size: 16, tint: LemonadeTheme.colors.content.contentSecondary)
            VStack(alignment: .leading, spacing: 2) {
                LemonadeUi.Text(
                    model.isComputingSizes ? "Calculating disk usage…" : "Calculate disk usage?",
                    textStyle: LemonadeTypography.shared.bodySmallMedium,
                    color: LemonadeTheme.colors.content.contentPrimary
                )
                LemonadeUi.Text(
                    "Reads every file in \(model.sizableCheckouts) checkouts. Cached sizes stay on screen either way.",
                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                    color: LemonadeTheme.colors.content.contentSecondary
                )
            }
            Spacer()
            actions()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
        )
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .accessibilityIdentifier("projectsSizeScanBar")
    }

    /// Opens the app-wide Herdr config (the Claude command Herdr runs).
    private var herdrSettingsButton: some View {
        Button(action: { model.openHerdrSettings() }) {
            LemonadeUi.Icon(
                icon: .gear, contentDescription: "Herdr settings", size: .small,
                tint: LemonadeTheme.colors.content.contentSecondary
            )
        }
        .buttonStyle(.plain)
        .help("Herdr settings — configure the Claude command")
    }

    private var viewModePicker: some View {
        Picker("", selection: Binding(
            get: { model.viewMode },
            set: { newValue in withAnimation(.easeInOut(duration: 0.18)) { model.viewMode = newValue } }
        )) {
            Text("Tree").tag(ProjectsViewMode.tree)
            Text("List").tag(ProjectsViewMode.list)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("projectsViewModePicker")
    }

    private var listSection: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(model.nodes) { node in
                    ProjectNodeView(
                        node: node,
                        model: model,
                        onToggle: { id in
                            withAnimation(.easeInOut(duration: 0.2)) { model.toggle(id) }
                        }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity)
    }

    private var firstLoadState: some View {
        VStack(spacing: 12) {
            LemonadeUi.Spinner()
            LemonadeUi.Text(
                "Scanning ~/.claude/projects…",
                textStyle: LemonadeTypography.shared.bodyMediumRegular,
                color: LemonadeTheme.colors.content.contentSecondary
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("projectsFirstLoad")
    }

    private var emptyState: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing300) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LemonadeTheme.colors.background.bgBrandSubtle)
                .frame(width: 64, height: 64)
                .overlay(GroveIcon(glyph: .folder, size: 32, tint: LemonadeTheme.colors.content.contentBrand))
            LemonadeUi.Text(
                "No projects found",
                textStyle: LemonadeTypography.shared.headingSmall,
                color: LemonadeTheme.colors.content.contentPrimary
            )
            LemonadeUi.Text(
                "Projects Claude Code has run in appear here automatically. You can also add any folder.",
                textStyle: LemonadeTypography.shared.bodyMediumRegular,
                textAlign: .center,
                color: LemonadeTheme.colors.content.contentSecondary
            )
            LemonadeUi.Button(
                label: "Add folder…",
                onClick: { model.addFolder() },
                leadingIcon: .plus,
                variant: .primary,
                type: .solid,
                size: .medium
            )
            .fixedSize()
            .padding(.top, LemonadeTheme.spaces.spacing200)
        }
        .padding(LemonadeTheme.spaces.spacing800)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("projectsEmptyState")
    }
}
