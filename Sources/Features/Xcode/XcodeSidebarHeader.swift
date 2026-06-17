import SwiftUI
import Lemonade

/// Sidebar section header for Xcode, styled to match the "Worktrees"/"Gradle" headers.
/// Tapping it navigates the main area to the DerivedData view; a small refresh icon
/// re-scans (and re-measures) the entries. Highlights when active.
struct XcodeSidebarHeader: View {
    @Bindable var model: AppModel

    private var active: Bool { model.mode == .xcode }

    var body: some View {
        HStack {
            LemonadeUi.Text(
                "Xcode",
                textStyle: LemonadeTypography.shared.headingXSmall,
                color: active
                    ? LemonadeTheme.colors.content.contentPrimary
                    : LemonadeTheme.colors.content.contentSecondary
            )
            Spacer()
            Button(action: { model.xcode.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
            }
            .buttonStyle(.plain)
            .help("Rescan DerivedData")
            .accessibilityIdentifier("xcodeRefreshButton")
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing200)
        .padding(.vertical, LemonadeTheme.spaces.spacing100)
        .background(
            RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                .fill(active ? LemonadeTheme.colors.interaction.bgSubtleInteractive : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.mode = .xcode }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.top, LemonadeTheme.spaces.spacing200)
        .padding(.bottom, LemonadeTheme.spaces.spacing200)
        .accessibilityIdentifier("xcodeHeader")
    }
}
