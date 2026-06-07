import SwiftUI
import Lemonade

/// Top-level shell: device sidebar on the left, the active session (tab) on the
/// right with a tab strip above it.
struct RootView: View {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            DeviceSidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            detail
        }
        .task { model.startDiscovery() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.persistTabs() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.sessions.isEmpty {
            EmptySessionView()
        } else {
            VStack(spacing: 0) {
                TabStripView(model: model)
                Rectangle()
                    .fill(LemonadeTheme.colors.border.borderNeutralLow)
                    .frame(height: 1)
                if let log = model.selectedSession as? LogSession {
                    LogSessionView(session: log)
                        .id(log.id)
                } else if let net = model.selectedSession as? NetworkSession {
                    NetworkSessionView(session: net)
                        .id(net.id)
                } else {
                    EmptySessionView()
                }
            }
            .background(LemonadeTheme.colors.background.bgDefault)
        }
    }
}

struct EmptySessionView: View {
    var body: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing300) {
            LemonadeUi.Icon(
                icon: .bug, contentDescription: nil, size: .large,
                tint: LemonadeTheme.colors.content.contentSecondary
            )
            LemonadeUi.Text(
                "Squeeze",
                textStyle: LemonadeTypography.shared.headingSmall,
                color: LemonadeTheme.colors.content.contentPrimary
            )
            LemonadeUi.Text(
                "Select a device on the left to start a logcat session.",
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
