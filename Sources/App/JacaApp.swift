import SwiftUI
import AppKit
import Lemonade

/// Reverts any device proxy Jaca configured when the app quits normally
/// (`applicationWillTerminate` fires on Cmd-Q / the Quit menu). Catchable signals
/// are handled in `ProxyCleanup`; a hard SIGKILL is covered by the sidebar
/// "Revert" affordance.
final class JacaAppDelegate: NSObject, NSApplicationDelegate {
    /// Keep Jaca running (and its menu-bar icon visible) after the window is closed —
    /// it lives in the menu bar; quit explicitly from there or with ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProxyCleanup.revertAll()
    }
}

@main
struct JacaApp: App {
    @NSApplicationDelegateAdaptor(JacaAppDelegate.self) private var appDelegate
    @AppStorage("colorScheme") private var colorScheme = "dark"

    init() {
        // Register the Figtree faces bundled with the Lemonade design system so
        // LemonadeUi.Text renders in the brand typeface instead of the system font.
        LemonadeFonts.registerFonts()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(preferredScheme)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Worktrees") {
                    NotificationCenter.default.post(name: .openWorktrees, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        // Always-present menu-bar icon (stays even when the window is closed, since the
        // app no longer terminates on last-window-close). Opens/focuses the main window.
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.original)
        }
    }

    private var preferredScheme: ColorScheme? {
        switch colorScheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

/// Contents of the menu-bar dropdown.
private struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Jaca") {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
        }
        .keyboardShortcut("j", modifiers: [.command, .shift])

        Divider()

        Button("Quit Jaca") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
