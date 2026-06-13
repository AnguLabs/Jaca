import Foundation

/// On-disk cache of the last projects scan (including computed sizes), so the Projects
/// area renders instantly from the previous result instead of flashing empty while a
/// fresh scan (filesystem + git + `du`) runs in the background.
struct ProjectsCache: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = base
                .appendingPathComponent("Jaca", isDirectory: true)
                .appendingPathComponent("projects.json")
        }
    }

    func load() -> [Project]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([Project].self, from: data)
    }

    func save(_ projects: [Project]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
