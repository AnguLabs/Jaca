import SwiftUI
import Lemonade

/// A modal sheet listing the maintenance actions for a single checkout, each with a
/// description of exactly what it does. Replaces the inline Clean/Delete buttons so the
/// destructive bits live behind a deliberate, explained step. Delete is shown only for
/// linked worktrees (the main checkout can't be removed) and uses a two-click confirm.
struct CheckoutActionsSheet: View {
    let project: Project
    let checkout: ProjectCheckout
    let model: ProjectsModel

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            actionCard(
                icon: .sparkles,
                title: "Clean build cache",
                description: "Runs `./gradlew clean` (if present) and deletes the matching Xcode DerivedData. Frees build-cache space — safe to do, but the next build will be slower while it regenerates.",
                meta: "Cache here: \(formatSize(checkout.cacheMB)) of \(formatSize(checkout.sizeMB))",
                button: LemonadeUi.Button(
                    label: checkout.cleaning ? "Cleaning…" : "Clean cache",
                    onClick: { clean() },
                    leadingIcon: .trash,
                    variant: .neutral,
                    type: .solid,
                    size: .small,
                    enabled: !checkout.cleaning,
                    loading: checkout.cleaning
                )
            )

            if checkout.isMain {
                mainNote
            } else {
                actionCard(
                    icon: .trash,
                    title: "Delete worktree",
                    description: nil,
                    meta: checkout.sizeComputed ? "\(formatSize(checkout.sizeMB)) on disk" : nil,
                    button: LemonadeUi.Button(
                        label: confirmingDelete ? "Confirm delete?" : "Delete worktree",
                        onClick: { handleDelete() },
                        leadingIcon: .trash,
                        variant: .critical,
                        type: confirmingDelete ? .solid : .subtle,
                        size: .small
                    )
                )
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                LemonadeUi.Button(
                    label: "Close", onClick: { dismiss() },
                    variant: .neutral, type: .subtle, size: .small
                )
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(LemonadeTheme.colors.background.bgDefault)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
                .frame(width: 36, height: 36)
                .overlay(GroveIcon(
                    glyph: checkout.isMain ? .folder : .branch,
                    size: 18,
                    tint: LemonadeTheme.colors.content.contentPrimary
                ))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    LemonadeUi.Text(
                        checkout.name,
                        textStyle: LemonadeTypography.shared.bodyLargeMedium,
                        color: LemonadeTheme.colors.content.contentPrimary,
                        maxLines: 1
                    )
                    LemonadeUi.Tag(label: checkout.isMain ? "folder" : "worktree", voice: .neutral)
                }
                Text(checkout.displayPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private var mainNote: some View {
        LemonadeUi.Text(
            "This is the project's main checkout, so it can't be removed — only its build cache can be cleaned.",
            textStyle: LemonadeTypography.shared.bodySmallRegular,
            color: LemonadeTheme.colors.content.contentTertiary
        )
    }

    // MARK: - Action card

    private func actionCard(icon: LemonadeIcon, title: String, description: String?,
                            meta: String?, button: some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LemonadeUi.Icon(icon: icon, contentDescription: nil, size: .small,
                                tint: LemonadeTheme.colors.content.contentSecondary)
                LemonadeUi.Text(
                    title,
                    textStyle: LemonadeTypography.shared.bodyMediumSemiBold,
                    color: LemonadeTheme.colors.content.contentPrimary
                )
            }
            if let description {
                // Plain Text + fixedSize so the full description wraps instead of
                // truncating at a couple of lines.
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let meta {
                Text(meta)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
            }
            button.fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
        )
    }

    // MARK: - Actions

    private func clean() {
        model.clearCache(project: project.id, checkout: checkout.id)
        dismiss()
    }

    /// Two-click confirm: first tap arms (auto-resets after 3s), second deletes + dismisses.
    private func handleDelete() {
        if confirmingDelete {
            confirmingDelete = false
            model.deleteWorktree(project: project.id, checkout: checkout.id)
            dismiss()
        } else {
            confirmingDelete = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                confirmingDelete = false
            }
        }
    }
}
