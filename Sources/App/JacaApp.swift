import SwiftUI
import AppKit
import Lemonade

/// Reverts any device proxy Jaca configured when the app quits normally
/// (`applicationWillTerminate` fires on Cmd-Q / the Quit menu). Catchable signals
/// are handled in `ProxyCleanup`; a hard SIGKILL is covered by the sidebar
/// "Revert" affordance.
final class JacaAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenuBarItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProxyCleanup.revertAll()
    }

    /// A menu-bar (status) item so Jaca is reachable from the top bar like before.
    /// Clicking it brings the main window to the front. Uses the app icon rendered as
    /// a template (monochrome silhouette that adapts to a light/dark menu bar).
    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let icon = NSImage(named: "MenuBarIcon")
            icon?.size = NSSize(width: 18, height: 18)
            icon?.isTemplate = false   // the jackfruit art is colorful; template would flatten it
            button.image = icon
            button.toolTip = "Jaca"
            button.target = self
            button.action = #selector(focusMainWindow)
        }
        statusItem = item
    }

    @objc private func focusMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) } ?? NSApp.windows.first
        window?.makeKeyAndOrderFront(nil)
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
        WindowGroup {
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
    }

    private var preferredScheme: ColorScheme? {
        switch colorScheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
