import SwiftUI
import Lemonade

/// One project row: a folder avatar, the project name with its real path, badges
/// (Claude / worktree count), total on-disk size, and a chevron that expands its
/// checkouts. Hover reveals "Reveal in Finder"; user-added projects also get a "Remove
/// from list" affordance. Tapping the row expands the checkouts.
struct ProjectRow: View {
    let project: Project
    let isExpanded: Bool
    let model: ProjectsModel
    let onToggle: () -> Void

    @State private var hovering = false
    @State private var confirmingRemove = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                avatar

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        LemonadeUi.Text(
                            project.name,
                            textStyle: LemonadeTypography.shared.bodyMediumSemiBold,
                            color: LemonadeTheme.colors.content.contentPrimary,
                            maxLines: 1
                        )
                        if project.isClaudeProject { LemonadeUi.Tag(label: "Claude", voice: .positive) }
                        if project.hasWorktrees { LemonadeUi.Tag(label: worktreeTag, voice: .neutral) }
                    }
                    Text(project.displayPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                if hovering { hoverActions }

                if project.isGitRepo, project.sizesComputed {
                    Text(formatSize(project.totalSizeMB))
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                        .frame(minWidth: 64, alignment: .trailing)
                }

                LemonadeUi.Icon(
                    icon: .chevronRight, contentDescription: nil, size: .small,
                    tint: LemonadeTheme.colors.content.contentTertiary
                )
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(project.isExpandable ? 1 : 0)
                .animation(.easeInOut(duration: 0.18), value: isExpanded)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)

            if isExpanded {
                VStack(spacing: 1) {
                    ForEach(project.checkouts) { checkout in
                        ProjectCheckoutRow(project: project, checkout: checkout, model: model)
                    }
                }
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isExpanded ? LemonadeTheme.colors.background.bgNeutralSubtle : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { if project.isExpandable { onToggle() } }
        .onHover { hovering = $0 }
    }

    private var avatar: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
            .frame(width: 34, height: 34)
            .overlay(GroveIcon(glyph: .folder, size: 17, tint: LemonadeTheme.colors.content.contentPrimary))
    }

    @ViewBuilder private var hoverActions: some View {
        if project.source == .user {
            Button(action: { handleRemoveTap() }) {
                Text(confirmingRemove ? "Confirm?" : "Remove")
                    .font(.system(size: 11))
                    .foregroundStyle(confirmingRemove
                        ? LemonadeTheme.colors.content.contentCritical
                        : LemonadeTheme.colors.content.contentSecondary)
            }
            .buttonStyle(.plain)
            .help("Remove from list (keeps the folder on disk)")
        }
        Button(action: { model.reveal(project.url) }) {
            Image(systemName: "arrow.up.forward.app")
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
        }
        .buttonStyle(.plain)
        .help("Reveal in Finder")
    }

    private var worktreeTag: String {
        project.worktreeCount == 1 ? "1 worktree" : "\(project.worktreeCount) worktrees"
    }

    private func handleRemoveTap() {
        if confirmingRemove {
            confirmingRemove = false
            model.removeUserProject(project.id)
        } else {
            confirmingRemove = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                confirmingRemove = false
            }
        }
    }
}

/// A checkout sub-row under an expanded project: the main working tree (marked "folder")
/// or a linked worktree (marked "worktree"), with branch/age, Claude badges, on-disk
/// size, and inline Clean-cache (+ Delete for worktrees) using two-click confirms.
struct ProjectCheckoutRow: View {
    let project: Project
    let checkout: ProjectCheckout
    let model: ProjectsModel

    @State private var hovering = false
    @State private var confirmingClear = false
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 10) {
            GroveIcon(
                glyph: checkout.isMain ? .folder : .branch,
                size: 14,
                tint: checkout.orphan
                    ? LemonadeTheme.colors.content.contentCaution
                    : LemonadeTheme.colors.content.contentTertiary
            )
            .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    LemonadeUi.Text(
                        checkout.name,
                        textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                        color: LemonadeTheme.colors.content.contentPrimary,
                        maxLines: 1
                    )
                    typeTag
                    claudeTag
                    if checkout.orphan { LemonadeUi.Tag(label: "Orphan", voice: .warning) }
                }
                Text(subtitle)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if hovering {
                Button(action: { model.reveal(checkout.url) }) {
                    Image(systemName: "arrow.up.forward.app")
                        .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
            }

            Text(sizeText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(checkout.dropped
                    ? LemonadeTheme.colors.content.contentPositive
                    : LemonadeTheme.colors.content.contentPrimary)
                .frame(minWidth: 60, alignment: .trailing)
                .animation(.easeInOut, value: checkout.dropped)

            actions
        }
        .padding(.vertical, 7)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .contentShape(Rectangle())
        .opacity(checkout.removing ? 0 : 1)
        .animation(.easeInOut(duration: 0.28), value: checkout.removing)
        .onHover { hovering = $0 }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            LemonadeUi.Button(
                label: checkout.cleaning ? "Cleaning…" : (confirmingClear ? "Confirm?" : "Clean"),
                onClick: { handleClearTap() },
                leadingIcon: .trash,
                variant: .neutral,
                type: confirmingClear ? .solid : .subtle,
                size: .xSmall,
                enabled: !checkout.cleaning,
                loading: checkout.cleaning
            )
            .fixedSize()

            if !checkout.isMain {
                LemonadeUi.Button(
                    label: confirmingDelete ? "Confirm?" : "Delete",
                    onClick: { handleDeleteTap() },
                    leadingIcon: .trash,
                    variant: .critical,
                    type: confirmingDelete ? .solid : .subtle,
                    size: .xSmall
                )
                .fixedSize()
            }
        }
    }

    // MARK: - Tags

    private var typeTag: some View {
        LemonadeUi.Tag(label: checkout.isMain ? "folder" : "worktree", voice: .neutral)
    }

    @ViewBuilder private var claudeTag: some View {
        if checkout.hasClaudeSessions {
            LemonadeUi.Tag(label: "Claude", voice: .positive)
        } else if checkout.isClaudeManaged {
            LemonadeUi.Tag(label: "No project", voice: .neutral)
        }
    }

    // MARK: - Presentation

    private var subtitle: String {
        var parts: [String] = [checkout.displayPath]
        if checkout.orphan {
            parts.append(checkout.orphanKind == .detached ? "detached HEAD" : "branch gone")
        } else if let base = checkout.base {
            parts.append("from \(base)")
        }
        if let age = checkout.age ?? relativeAge(checkout.claudeLastActive) { parts.append(age) }
        return parts.joined(separator: " · ")
    }

    private var sizeText: String {
        if checkout.cleaning { return "cleaning…" }
        return checkout.sizeComputed ? formatSize(checkout.sizeMB) : "—"
    }

    // MARK: - Two-click confirms

    private func handleClearTap() {
        if confirmingClear {
            confirmingClear = false
            model.clearCache(project: project.id, checkout: checkout.id)
        } else {
            confirmingClear = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                confirmingClear = false
            }
        }
    }

    private func handleDeleteTap() {
        if confirmingDelete {
            confirmingDelete = false
            model.deleteWorktree(project: project.id, checkout: checkout.id)
        } else {
            confirmingDelete = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                confirmingDelete = false
            }
        }
    }
}
