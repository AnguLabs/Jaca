import AppKit
import Foundation

/// Entry points for opening a Worktrees tab. Shared by the sidebar button and the
/// File-menu command so both present the same picker.
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
    /// Posted (object: chosen folder `URL`) when the File-menu command picks a
    /// folder. `RootView` observes it because the menu can't reach `AppModel`.
    static let openWorktrees = Notification.Name("jaca.openWorktrees")
}
