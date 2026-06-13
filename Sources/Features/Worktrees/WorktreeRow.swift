import SwiftUI
import Lemonade

/// A single collapsed worktree row: a state-dependent avatar, the branch name with a
/// contextual subtitle, the on-disk size (with a green flash after a cache clear), an
/// optional Orphan tag, and a chevron that rotates open. Tapping anywhere on the row
/// toggles its open state. Authored against semantic Lemonade tokens.
struct WorktreeRow: View {
    let w: Worktree
    let isOpen: Bool
    let model: WorktreesModel
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                avatar

                VStack(alignment: .leading, spacing: 2) {
                    LemonadeUi.Text(
                        w.name,
                        textStyle: LemonadeTypography.shared.bodyMediumSemiBold,
                        color: LemonadeTheme.colors.content.contentPrimary,
                        maxLines: 1
                    )
                    LemonadeUi.Text(
                        subtitle,
                        textStyle: LemonadeTypography.shared.bodySmallRegular,
                        color: LemonadeTheme.colors.content.contentSecondary,
                        maxLines: 1
                    )
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(sizeText)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(
                            w.dropped
                                ? LemonadeTheme.colors.content.contentPositive
                                : LemonadeTheme.colors.content.contentPrimary
                        )
                        .animation(.easeInOut, value: w.dropped)

                    tag
                }

                LemonadeUi.Icon(
                    icon: .chevronRight,
                    contentDescription: nil,
                    size: .small,
                    tint: LemonadeTheme.colors.content.contentTertiary
                )
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .animation(.easeInOut(duration: 0.18), value: isOpen)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)

            if isOpen {
                WorktreeActionsView(w: w, model: model)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isOpen ? LemonadeTheme.colors.background.bgNeutralSubtle : Color.clear)
        )
        .overlay(ring)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .opacity(w.removing ? 0 : 1)
        .animation(.easeInOut(duration: 0.28), value: w.removing)
    }

    // MARK: - Avatar

    @ViewBuilder private var avatar: some View {
        let (fill, glyph, tint) = avatarStyle
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(fill)
            .frame(width: 34, height: 34)
            .overlay(GroveIcon(glyph: glyph, size: 17, tint: tint))
    }

    private var avatarStyle: (fill: Color, glyph: GroveGlyph, tint: Color) {
        if w.orphan {
            return (LemonadeTheme.colors.background.bgCautionSubtle, .unlink, LemonadeTheme.colors.content.contentCaution)
        } else {
            return (LemonadeTheme.colors.background.bgNeutralSubtle, .branch, LemonadeTheme.colors.content.contentPrimary)
        }
    }

    // MARK: - Subtitle

    private var subtitle: String {
        if w.orphan {
            return w.kind == .detached ? "Detached HEAD · no branch" : "Branch deleted upstream"
        } else {
            return "from \(w.base) · \(w.age)"
        }
    }

    // MARK: - Size

    private var sizeText: String {
        if w.cleaning { return "cleaning…" }
        return w.sizeComputed ? formatSize(w.sizeMB) : "—"
    }

    // MARK: - Tag

    @ViewBuilder private var tag: some View {
        if w.orphan {
            LemonadeUi.Tag(label: "Orphan", voice: .warning)
        }
    }

    // MARK: - Ring

    @ViewBuilder private var ring: some View {
        if w.orphan {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(LemonadeTheme.colors.content.contentCaution.opacity(0.3), lineWidth: 1)
        }
    }
}
