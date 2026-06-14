import SwiftUI
import Lemonade

private let nodeIndent: CGFloat = 16

/// A project node row (used by both LIST and TREE views). Shows the project's folder,
/// badges (Claude / sub-project or worktree counts), total size, and a chevron. Expanding
/// reveals nested sub-projects (TREE) and/or the project's checkouts (main + worktrees).
/// `depth` indents nested levels. Recursive for the tree.
struct ProjectNodeView: View {
    let node: ProjectNode
    var depth: Int = 0
    let model: ProjectsModel
    let onToggle: (String) -> Void

    @State private var hovering = false
    @State private var confirmingRemove = false

    private var project: Project { node.project }
    private var isExpanded: Bool { model.isExpanded(node.id) }
    private var hasCheckouts: Bool { !project.checkouts.isEmpty }
    private var isExpandable: Bool { node.hasChildren || hasCheckouts }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
                .padding(.vertical, 9)
                .padding(.trailing, 10)
                .padding(.leading, 10 + CGFloat(depth) * nodeIndent)
                .contentShape(Rectangle())
                .onTapGesture { if isExpandable { onToggle(node.id) } }
                .onHover { hovering = $0 }

            if isExpanded {
                VStack(spacing: 1) {
                    ForEach(node.children) { child in
                        ProjectNodeView(node: child, depth: depth + 1, model: model, onToggle: onToggle)
                    }
                    ForEach(project.checkouts) { checkout in
                        ProjectCheckoutRow(project: project, checkout: checkout, depth: depth, model: model)
                    }
                }
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isExpanded && hasCheckouts ? LemonadeTheme.colors.background.bgNeutralSubtle : .clear)
        )
    }

    private var headerRow: some View {
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
                    if node.hasChildren { LemonadeUi.Tag(label: projectsTag, voice: .neutral) }
                    if project.hasWorktrees { LemonadeUi.Tag(label: worktreeTag, voice: .neutral) }
                }
                Text(project.displayPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if hovering, project.source == .user { removeButton }

            if model.herdrInstalled, project.isClaudeProject, let herdrIcon = model.herdrIcon {
                OpenInAppButton(icon: herdrIcon, help: "Open in Herdr (new worktree)", iconCornerRadius: 4) {
                    model.openInHerdr(
                        projectRoot: project.url, projectName: project.name,
                        folder: project.url, isWorktree: false, hasGit: project.isGitRepo
                    )
                }
            }
            if let zed = model.zed {
                OpenInAppButton(icon: zed.icon, help: "Open in \(zed.name)") { model.openInZed(project.url) }
            }
            OpenInAppButton(icon: model.finderIcon, help: "Open in Finder") { model.openInFinder(project.url) }

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
            .opacity(isExpandable ? 1 : 0)
            .animation(.easeInOut(duration: 0.18), value: isExpanded)
        }
    }

    private var avatar: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(node.hasChildren
                  ? LemonadeTheme.colors.background.bgBrandSubtle
                  : LemonadeTheme.colors.background.bgNeutralSubtle)
            .frame(width: 34, height: 34)
            .overlay(GroveIcon(
                glyph: .folder,
                size: 17,
                tint: node.hasChildren
                    ? LemonadeTheme.colors.content.contentBrand
                    : LemonadeTheme.colors.content.contentPrimary
            ))
    }

    /// Shown only on hover for user-added projects: removes the project from the list
    /// (keeps the folder on disk). Two-click confirm.
    private var removeButton: some View {
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

    private var projectsTag: String {
        node.children.count == 1 ? "1 project" : "\(node.children.count) projects"
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
    var depth: Int = 0
    let model: ProjectsModel

    @State private var hovering = false
    @State private var showingActions = false

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

            if model.herdrInstalled, project.isClaudeProject, let herdrIcon = model.herdrIcon {
                OpenInAppButton(icon: herdrIcon, help: herdrHelp, iconCornerRadius: 4) {
                    model.openInHerdr(
                        projectRoot: project.url, projectName: project.name,
                        folder: checkout.url, isWorktree: !checkout.isMain, hasGit: project.isGitRepo
                    )
                }
            }
            if let zed = model.zed {
                OpenInAppButton(icon: zed.icon, help: "Open in \(zed.name)") { model.openInZed(checkout.url) }
            }
            OpenInAppButton(icon: model.finderIcon, help: "Open in Finder") { model.openInFinder(checkout.url) }

            Text(sizeText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(checkout.dropped
                    ? LemonadeTheme.colors.content.contentPositive
                    : LemonadeTheme.colors.content.contentPrimary)
                .frame(minWidth: 60, alignment: .trailing)
                .animation(.easeInOut, value: checkout.dropped)

            configButton
        }
        .padding(.vertical, 7)
        .padding(.trailing, 12)
        .padding(.leading, 10 + CGFloat(depth + 1) * nodeIndent)
        .contentShape(Rectangle())
        .opacity(checkout.removing ? 0 : 1)
        .animation(.easeInOut(duration: 0.28), value: checkout.removing)
        .onHover { hovering = $0 }
        .sheet(isPresented: $showingActions) {
            CheckoutActionsSheet(project: project, checkout: checkout, model: model)
        }
    }

    /// A single gear button that opens the actions sheet (Clean / Delete with descriptions).
    private var configButton: some View {
        Button(action: { showingActions = true }) {
            LemonadeUi.Icon(
                icon: .gear,
                contentDescription: "Configure",
                size: .small,
                tint: checkout.cleaning
                    ? LemonadeTheme.colors.content.contentTertiary
                    : LemonadeTheme.colors.content.contentSecondary
            )
        }
        .buttonStyle(.plain)
        .disabled(checkout.cleaning)
        .help("Cache & worktree actions")
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

    /// The main checkout starts a fresh worktree; a linked worktree opens in place.
    private var herdrHelp: String {
        checkout.isMain ? "Open in Herdr (new worktree)" : "Open in Herdr"
    }
}
