import SwiftUI
import Lemonade

/// A compact, always-visible launch button showing an app's real icon (e.g. Zed, Finder).
/// Used in the Projects list to open a project/worktree folder in that app. The real app
/// icon makes the action recognizable at a glance; a soft rounded highlight on hover keeps
/// it interactive without the cramped, hover-only feel of a small SF Symbol.
struct OpenInAppButton: View {
    let icon: NSImage
    let help: String
    /// Rounds the icon's corners — for square logos (e.g. Herdr) so they read as app icons
    /// alongside the already-rounded macOS icons. nil leaves the icon as-is.
    var iconCornerRadius: CGFloat? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: iconCornerRadius ?? 0, style: .continuous))
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering
                              ? LemonadeTheme.colors.interaction.bgSubtleInteractive
                              : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .help(help)
    }
}
