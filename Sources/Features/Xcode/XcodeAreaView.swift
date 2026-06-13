import SwiftUI
import Lemonade

/// The main-pane content for the Xcode top-level mode: the DerivedData entries with
/// their sizes and a LIVE/STALE/Shared tag, each with a 2-click-confirm Delete. A
/// header shows the total and a "Clean stale" action. Mirrors `GradleDaemonsView`'s
/// structure (header card, scrollable list, bottom-center toast). Refreshes on appear.
struct XcodeAreaView: View {
    let model: DerivedDataModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LemonadeTheme.colors.background.bgDefault)
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    XcodeToastView(toast: toast)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.toast)
            .onAppear { if model.entries.isEmpty { model.refresh() } }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            header
            listSection
        }
    }

    /// "DERIVED DATA" overline + total size, plus a 2-click "Clean stale" action.
    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                LemonadeUi.Text(
                    "DERIVED DATA",
                    textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                    color: LemonadeTheme.colors.content.contentTertiary
                )
                LemonadeUi.Text(
                    "\(formatSize(model.totalMB)) total · \(model.entries.count) entries",
                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                    color: LemonadeTheme.colors.content.contentSecondary
                )
            }
            Spacer()
            if model.staleCount > 0 {
                CleanStaleButton(model: model)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
        )
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    @ViewBuilder private var listSection: some View {
        if model.entries.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(model.entries) { entry in
                        DerivedDataRow(entry: entry, model: model)
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
            model.isLoading ? "Scanning DerivedData…" : "No DerivedData found",
            textStyle: LemonadeTypography.shared.bodyMediumRegular,
            textAlign: .center,
            color: LemonadeTheme.colors.content.contentSecondary
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityIdentifier("xcodeEmptyState")
    }
}

/// A 2-click-confirm button that deletes every stale entry at once.
private struct CleanStaleButton: View {
    let model: DerivedDataModel
    @State private var confirming = false

    var body: some View {
        LemonadeUi.Button(
            label: confirming
                ? "Confirm? (\(formatSize(model.staleMB)))"
                : "Clean \(model.staleCount) stale",
            onClick: { handleTap() },
            leadingIcon: .trash,
            variant: .critical,
            type: confirming ? .solid : .subtle,
            size: .xSmall
        )
        .fixedSize()
    }

    private func handleTap() {
        if confirming {
            confirming = false
            model.cleanAllStale()
        } else {
            confirming = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                confirming = false
            }
        }
    }
}

/// One row per DerivedData entry: an avatar, the project (or cache) name with its
/// workspace path as subtitle, a LIVE/STALE/Shared tag, the size, and a two-click
/// Delete button.
struct DerivedDataRow: View {
    let entry: DerivedDataEntry
    let model: DerivedDataModel
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 11) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                LemonadeUi.Text(
                    entry.name,
                    textStyle: LemonadeTypography.shared.bodyMediumSemiBold,
                    color: LemonadeTheme.colors.content.contentPrimary,
                    maxLines: 1
                )
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            LemonadeUi.Tag(label: tagLabel, voice: tagVoice)

            Text(formatSize(entry.sizeMB))
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                .frame(minWidth: 64, alignment: .trailing)

            LemonadeUi.Button(
                label: confirming ? "Confirm?" : "Delete",
                onClick: { handleTap() },
                leadingIcon: .trash,
                variant: .critical,
                type: confirming ? .solid : .subtle,
                size: .xSmall
            )
            .fixedSize()
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .opacity(entry.removing ? 0 : 1)
        .animation(.easeInOut(duration: 0.28), value: entry.removing)
    }

    // MARK: - Avatar

    private var avatar: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
            .frame(width: 34, height: 34)
            .overlay(
                LemonadeUi.Icon(
                    icon: .hammer,
                    contentDescription: nil,
                    size: .small,
                    tint: LemonadeTheme.colors.content.contentPrimary
                )
            )
    }

    // MARK: - Presentation

    private var subtitle: String {
        entry.workspacePath ?? "Shared cache"
    }

    private var tagLabel: String {
        switch entry.kind {
        case .live: return "LIVE"
        case .stale: return "STALE"
        case .shared: return "SHARED"
        }
    }

    private var tagVoice: TagVoice {
        switch entry.kind {
        case .live: return .positive
        case .stale: return .warning
        case .shared: return .neutral
        }
    }

    // MARK: - Delete (two-click confirm)

    private func handleTap() {
        if confirming {
            confirming = false
            model.delete(entry.path)
        } else {
            confirming = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                confirming = false
            }
        }
    }
}
