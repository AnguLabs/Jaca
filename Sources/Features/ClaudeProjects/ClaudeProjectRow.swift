import SwiftUI
import Lemonade

/// One project row: a folder avatar, the project name with its real path as a
/// monospaced subtitle, session/worktree tags, and a chevron that expands the
/// worktree sub-rows. Hovering reveals a "Reveal in Finder" affordance. Tapping the
/// row toggles its worktrees (when it has any). Authored against semantic Lemonade
/// tokens, mirroring `WorktreeRow`.
struct ClaudeProjectRow: View {
    let project: ClaudeProject
    let isExpanded: Bool
    let model: ClaudeProjectsModel
    let onToggle: () -> Void

    @State private var hovering = false

    private var hasWorktrees: Bool { project.worktreeCount > 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                avatar

                VStack(alignment: .leading, spacing: 2) {
                    LemonadeUi.Text(
                        project.name,
                        textStyle: LemonadeTypography.shared.bodyMediumSemiBold,
                        color: LemonadeTheme.colors.content.contentPrimary,
                        maxLines: 1
                    )
                    Text(project.displayPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                if hovering {
                    Button(action: { model.reveal(project.url) }) {
                        Image(systemName: "arrow.up.forward.app")
                            .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                }

                trailingMeta

                LemonadeUi.Icon(
                    icon: .chevronRight,
                    contentDescription: nil,
                    size: .small,
                    tint: LemonadeTheme.colors.content.contentTertiary
                )
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(hasWorktrees ? 1 : 0)
                .animation(.easeInOut(duration: 0.18), value: isExpanded)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)

            if isExpanded {
                VStack(spacing: 1) {
                    ForEach(project.worktrees) { wt in
                        ClaudeWorktreeRow(worktree: wt, model: model)
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
        .onTapGesture { if hasWorktrees { onToggle() } }
        .onHover { hovering = $0 }
    }

    // MARK: - Avatar

    private var avatar: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
            .frame(width: 34, height: 34)
            .overlay(
                GroveIcon(
                    glyph: .folder,
                    size: 17,
                    tint: LemonadeTheme.colors.content.contentPrimary
                )
            )
    }

    // MARK: - Trailing meta (counts + tags)

    @ViewBuilder private var trailingMeta: some View {
        HStack(spacing: 6) {
            if project.sessionCount > 0 {
                Text("\(project.sessionCount) \(project.sessionCount == 1 ? "session" : "sessions")")
                    .font(.system(size: 11))
                    .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
            }
            if hasWorktrees {
                LemonadeUi.Tag(label: worktreeTag, voice: .neutral)
            }
        }
    }

    private var worktreeTag: String {
        project.worktreeCount == 1 ? "1 worktree" : "\(project.worktreeCount) worktrees"
    }
}

/// A worktree sub-row shown under an expanded project: a branch avatar, the branch (or
/// folder) name with its path, a "Claude" tag when it has sessions, and the last commit
/// age. Hover reveals a "Reveal in Finder" affordance.
struct ClaudeWorktreeRow: View {
    let worktree: ClaudeWorktree
    let model: ClaudeProjectsModel

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            GroveIcon(
                glyph: .branch,
                size: 14,
                tint: LemonadeTheme.colors.content.contentTertiary
            )
            .frame(width: 34, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                LemonadeUi.Text(
                    worktree.name,
                    textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                    color: LemonadeTheme.colors.content.contentPrimary,
                    maxLines: 1
                )
                Text(worktree.displayPath)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if hovering && worktree.exists {
                Button(action: { model.reveal(worktree.url) }) {
                    Image(systemName: "arrow.up.forward.app")
                        .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
            }

            // A worktree under `.claude/worktrees/` is Claude-created, so it's marked
            // "Claude" even when its session history was cleaned up — in which case it
            // also gets a muted "No project" tag.
            if worktree.isClaudeManaged || worktree.hasClaudeSessions {
                LemonadeUi.Tag(label: "Claude", voice: .positive)
            }
            if worktree.isClaudeManaged && !worktree.hasClaudeSessions {
                LemonadeUi.Tag(label: "No project", voice: .neutral)
            }
            if let age = subtitleAge {
                Text(age)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Prefer git's commit age; otherwise the session's last-active time.
    private var subtitleAge: String? {
        worktree.age ?? relativeAge(worktree.lastActive)
    }
}
