import AppKit
import Foundation

/// Folder-picker entry point for the Projects area (adding a project folder).
enum ProjectsOpen {
    /// Shows a directory picker; returns the chosen folder or nil.
    @MainActor static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a project folder (a git repo with worktrees, or any folder)"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension Notification.Name {
    /// Posted by the ⌘⇧O menu command to switch to the Projects area. `RootView`
    /// observes it because the menu can't reach `AppModel`.
    static let openProjects = Notification.Name("jaca.openProjects")
}
