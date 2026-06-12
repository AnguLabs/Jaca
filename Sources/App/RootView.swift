import SwiftUI
import Lemonade
import AppKit

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
        .task {
            model.startDiscovery()
            // Bring the window frontmost so it becomes key on launch.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.persistTabs() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWorktrees)) { note in
            if let folder = note.object as? URL { model.openWorktreesTab(folder: folder) }
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
                // Keep every tab's view alive and just show the selected one, so
                // switching tabs preserves scroll position / selection / state instead
                // of recreating the view (which caused a full redraw + scroll jump).
                ZStack {
                    ForEach(model.sessions, id: \.id) { session in
                        let active = session.id == model.selectedSessionID
                        sessionView(for: session, isActive: active)
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                            .zIndex(active ? 1 : 0)
                    }
                }
            }
            .background(LemonadeTheme.colors.background.bgDefault)
        }
    }

    @ViewBuilder
    private func sessionView(for session: any WorkspaceTab, isActive: Bool) -> some View {
        if let log = session as? LogSession {
            LogSessionView(session: log, isActive: isActive)
        } else if let net = session as? NetworkSession {
            NetworkSessionView(session: net)
        } else if let wt = session as? WorktreesTab {
            WorktreesView(tab: wt)
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
                "Jaca",
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
        .accessibilityIdentifier("emptyState")
    }
}
