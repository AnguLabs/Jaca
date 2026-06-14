import SwiftUI
import AppKit
import Lemonade

/// Owns the menu-bar status item. Left-click opens/focuses the window; right-click (or
/// control-click) shows a menu (Open / Quit). The app lives in the menu bar only (no Dock
/// icon) and stays running when the window is closed — closing just hides the window so a
/// left-click can bring it right back.
final class JacaAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
        installStatusItem()
        adoptMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        ProxyCleanup.revertAll()
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let icon = (NSImage(named: "MenuBarIcon")?.copy() as? NSImage)
            icon?.size = NSSize(width: 18, height: 18)
            icon?.isTemplate = false
            button.image = icon
            button.toolTip = "Jaca"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isRight {
            showMenu()
        } else {
            openWindow()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Jaca", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        addUpdateItem(to: menu)
        let quit = NSMenuItem(title: "Quit Jaca", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Attach transiently so this click pops the menu, then detach so the next
        // left-click runs the action instead of opening the menu.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    /// Adds an "Update Jaca" item when one is available, or a disabled progress line
    /// while an update runs. Nothing when up to date or the feature is off.
    private func addUpdateItem(to menu: NSMenu) {
        MainActor.assumeIsolated {
            let update = UpdateModel.shared
            guard update.enabled else { return }
            let item: NSMenuItem
            if let phase = update.phase {
                item = NSMenuItem(title: "Updating — \(phase.label)", action: nil, keyEquivalent: "")
                item.isEnabled = false
            } else if update.updateAvailable {
                item = NSMenuItem(title: "Update Jaca", action: #selector(runUpdate), keyEquivalent: "")
                item.target = self
            } else if update.isChecking {
                item = NSMenuItem(title: "Checking for updates…", action: nil, keyEquivalent: "")
                item.isEnabled = false
            } else {
                item = NSMenuItem(title: "Check for Updates", action: #selector(checkUpdate), keyEquivalent: "")
                item.target = self
            }
            menu.addItem(item)
            menu.addItem(.separator())
        }
    }

    @objc private func openWindow() {
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func runUpdate() {
        MainActor.assumeIsolated { UpdateModel.shared.runUpdate() }
    }

    @objc private func checkUpdate() {
        MainActor.assumeIsolated { UpdateModel.shared.check() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Keep the window alive (hide on close)

    /// Grab the WindowGroup's window once it exists, become its delegate so the red
    /// close button hides it (kept alive) instead of destroying it.
    private func adoptMainWindow() {
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            mainWindow = window
            window.isReleasedWhenClosed = false
            window.delegate = self
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.adoptMainWindow() }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)   // hide instead of close, so left-click can bring it back
        return false
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
                Button("Projects") {
                    NotificationCenter.default.post(name: .openProjects, object: nil)
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
