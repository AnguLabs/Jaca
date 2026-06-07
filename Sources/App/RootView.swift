import SwiftUI
import Lemonade

/// Top-level shell: device sidebar on the left, the active log session (tab) on
/// the right. Phase 0 ships the themed scaffold with empty states; the device
/// list, tab strip, and log view are filled in by later phases.
struct RootView: View {
    var body: some View {
        NavigationSplitView {
            DeviceSidebarPlaceholder()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            EmptySessionView()
        }
        .background(LemonadeTheme.colors.background.bgDefault)
    }
}

private struct DeviceSidebarPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing300) {
            LemonadeUi.Text(
                "Devices",
                textStyle: LemonadeTypography.shared.headingXSmall,
                color: LemonadeTheme.colors.content.contentPrimary
            )
            .padding(.top, LemonadeTheme.spaces.spacing200)

            Spacer()

            HStack {
                Spacer()
                VStack(spacing: LemonadeTheme.spaces.spacing200) {
                    LemonadeUi.Icon(
                        icon: .smartphone,
                        contentDescription: nil,
                        size: .large,
                        tint: LemonadeTheme.colors.content.contentSecondary
                    )
                    LemonadeUi.Text(
                        "No devices connected",
                        textStyle: LemonadeTypography.shared.bodySmallRegular,
                        textAlign: .center,
                        color: LemonadeTheme.colors.content.contentSecondary
                    )
                }
                Spacer()
            }

            Spacer()
        }
        .padding(LemonadeTheme.spaces.spacing300)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LemonadeTheme.colors.background.bgElevated)
    }
}

private struct EmptySessionView: View {
    var body: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing300) {
            LemonadeUi.Icon(
                icon: .bug,
                contentDescription: nil,
                size: .large,
                tint: LemonadeTheme.colors.content.contentSecondary
            )
            LemonadeUi.Text(
                "Squeeze",
                textStyle: LemonadeTypography.shared.headingSmall,
                color: LemonadeTheme.colors.content.contentPrimary
            )
            LemonadeUi.Text(
                "Select a device and start a logcat session.",
                textStyle: LemonadeTypography.shared.bodyMediumRegular,
                textAlign: .center,
                color: LemonadeTheme.colors.content.contentSecondary
            )
        }
        .padding(LemonadeTheme.spaces.spacing800)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LemonadeTheme.colors.background.bgDefault)
    }
}
