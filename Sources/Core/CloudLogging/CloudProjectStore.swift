import Foundation

/// A configured GCP project + its global (per-project) Cloud Logging state. Persisted to
/// `~/.jaca/cloud-logging/projects.json`. The `selectedLogName`, cached `logNames`, and
/// auto-detected label keys are deliberately *global per project* (req 7): every open
/// session for the project reads them, so switching the log name in one tab is reflected
/// everywhere.
struct CloudProject: Codable, Sendable, Hashable, Identifiable {
    var projectID: String
    var displayName: String = ""
    /// Currently selected full log name (`projects/<id>/logs/<encoded>`), shared by all sessions.
    var selectedLogName: String?
    /// Cached list of available full log names (from `gcloud logging logs list`).
    var logNames: [String] = []
    /// Auto-detected label keys, cached per log name (req 9.3).
    var labelKeysByLogName: [String: [String]] = [:]

    var id: String { projectID }
    /// What the sidebar/tab shows: the display name if set, else the raw id.
    var title: String { displayName.isEmpty ? projectID : displayName }

    /// Label keys detected for the currently selected log name (or the project-wide bucket,
    /// keyed by "", when no log name is selected — so the labels system works either way).
    var currentLabelKeys: [String] {
        labelKeysByLogName[selectedLogName ?? ""] ?? []
    }
}

/// On-disk store for cloud project configs. Lives under `~/.jaca/` (per the product spec —
/// easy to inspect/edit by hand), with atomic writes. Mirrors `ProjectsCache` /
/// `CompanionDeviceStore`.
struct CloudProjectStore: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".jaca", isDirectory: true)
                .appendingPathComponent("cloud-logging", isDirectory: true)
                .appendingPathComponent("projects.json")
        }
    }

    func load() -> [CloudProject] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([CloudProject].self, from: data)) ?? []
    }

    func save(_ projects: [CloudProject]) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
