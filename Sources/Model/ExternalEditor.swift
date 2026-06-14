import AppKit
import Foundation

/// An external code editor Jaca can hand a project/worktree folder to. Resolved by macOS
/// bundle identifier, so an editor surfaces as an action only when it's actually installed.
/// Adding another editor is a one-liner: extend `Kind` with its display name and bundle
/// IDs — detection, the branded icon, and launching are all generic over `Kind`.
struct ExternalEditor: Equatable, Identifiable {
    enum Kind: String, CaseIterable {
        case zed

        var displayName: String {
            switch self {
            case .zed: return "Zed"
            }
        }

        /// Bundle identifiers to probe, most-preferred first (stable, then preview/nightly/dev),
        /// so the released build wins when several channels are installed side by side.
        var bundleIdentifiers: [String] {
            switch self {
            case .zed: return ["dev.zed.Zed", "dev.zed.Zed-Preview", "dev.zed.Zed-Nightly", "dev.zed.Zed-Dev"]
            }
        }

        /// A bundled CLI (path relative to the `.app`) and the args that open a folder in a
        /// *new* window, plus the folder path. Preferred over `NSWorkspace.open`, which hands
        /// the folder to the running app and reuses its window. Nil → fall back to NSWorkspace.
        var newWindowCLI: (path: String, args: [String])? {
            switch self {
            case .zed: return ("Contents/MacOS/cli", ["--new"])
            }
        }
    }

    let kind: Kind
    /// The installed `.app` bundle on disk, as resolved by `NSWorkspace`.
    let appURL: URL

    var id: String { kind.rawValue }
    var name: String { kind.displayName }

    /// The editor's real app icon — lets the launch button show recognizable branding
    /// instead of a generic glyph. Pulled live from `NSWorkspace`, not stored, so it's
    /// excluded from `Equatable` (which compares `kind` + `appURL`).
    var icon: NSImage { NSWorkspace.shared.icon(forFile: appURL.path) }

    /// Resolves where `kind` is installed, or nil when it isn't (the action then stays hidden).
    static func detect(_ kind: Kind) -> ExternalEditor? {
        let workspace = NSWorkspace.shared
        for id in kind.bundleIdentifiers {
            if let url = workspace.urlForApplication(withBundleIdentifier: id) {
                return ExternalEditor(kind: kind, appURL: url)
            }
        }
        return nil
    }

    /// Opens `folder` as a workspace/project in this editor — in a *new* window each call,
    /// via the editor's bundled CLI. Falls back to `NSWorkspace` (which reuses the running
    /// app's window) only when the CLI is missing or fails to launch.
    func open(_ folder: URL) {
        if let cli = kind.newWindowCLI {
            let cliURL = appURL.appendingPathComponent(cli.path)
            if FileManager.default.isExecutableFile(atPath: cliURL.path),
               launch(cliURL, cli.args + [folder.path]) {
                return
            }
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: config, completionHandler: nil)
    }

    /// Fire-and-forget launch of a short-lived CLI (it signals the editor and exits, so we
    /// don't wait). Returns whether the process started.
    private func launch(_ executable: URL, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        do { try process.run(); return true } catch { return false }
    }
}
