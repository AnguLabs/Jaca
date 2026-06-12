import SwiftUI
import Lemonade

/// The expanded action drawer revealed beneath a worktree row. Shows a compact meta line
/// (cache size) and two actions: Clear cache (always) and Delete. Both use a two-click
/// inline confirm. Wired straight into `WorktreesTab`. Authored against semantic Lemonade
/// tokens.
struct WorktreeActionsView: View {
    let w: Worktree
    let tab: WorktreesTab
    @State private var confirmingDelete = false
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            metaLine
            buttons
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.bottom, 12)
    }

    // MARK: - Meta line

    private var metaLine: some View {
        HStack(spacing: 18) {
            segment("cache", value: formatSize(w.cacheMB))
        }
    }

    private func segment(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            LemonadeUi.Text(
                label,
                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                color: LemonadeTheme.colors.content.contentSecondary
            )
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        FlowLayout(spacing: 7, lineSpacing: 7) {
            LemonadeUi.Button(
                label: w.cleaning ? "Cleaning…" : (confirmingClear ? "Confirm clear?" : "Clear cache"),
                onClick: { handleClearTap() },
                leadingIcon: .trash,
                variant: .neutral,
                type: confirmingClear ? .solid : .subtle,
                size: .small,
                enabled: !w.cleaning,
                loading: w.cleaning
            )

            LemonadeUi.Button(
                label: confirmingDelete ? "Confirm delete?" : "Delete",
                onClick: { handleDeleteTap() },
                leadingIcon: .trash,
                variant: .critical,
                type: confirmingDelete ? .solid : .subtle,
                size: .small
            )
        }
    }

    /// Two-click guard: first tap arms the confirm (auto-resets after 3s), second tap deletes.
    private func handleDeleteTap() {
        if confirmingDelete {
            confirmingDelete = false
            tab.deleteWorktree(w.id)
        } else {
            confirmingDelete = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                confirmingDelete = false
            }
        }
    }

    /// Two-click guard for clearing caches (recoverable, but slow to rebuild).
    private func handleClearTap() {
        if confirmingClear {
            confirmingClear = false
            tab.clearCache(w.id)
        } else {
            confirmingClear = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                confirmingClear = false
            }
        }
    }
}
