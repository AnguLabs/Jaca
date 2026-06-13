import AppKit
import Foundation

/// Folder-picker entry point for the Worktrees area. The area's "Choose folder…" /
/// "Change" affordances call `pickFolder()` directly.
enum WorktreesOpen {
    /// Shows a directory picker; returns the chosen folder or nil.
    @MainActor static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder that holds git worktrees"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension Notification.Name {
    /// Posted by the ⌘⇧O menu command to switch to the Worktrees mode. `RootView`
    /// observes it because the menu can't reach `AppModel`.
    static let openWorktrees = Notification.Name("jaca.openWorktrees")
}
