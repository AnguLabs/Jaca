import SwiftUI
import AppKit
import Lemonade

/// Reverts any device proxy Jaca configured when the app quits normally
/// (`applicationWillTerminate` fires on Cmd-Q / the Quit menu). Catchable signals
/// are handled in `ProxyCleanup`; a hard SIGKILL is covered by the sidebar
/// "Revert" affordance.
final class JacaAppDelegate: NSObject, NSApplicationDelegate {
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
        WindowGroup {
            RootView()
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(preferredScheme)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Worktrees…") {
                    if let folder = WorktreesOpen.pickFolder() {
                        NotificationCenter.default.post(name: .openWorktrees, object: folder)
                    }
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
