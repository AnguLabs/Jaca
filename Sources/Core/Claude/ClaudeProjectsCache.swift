import Foundation

/// On-disk cache of the last `ClaudeProjectsScanner` result, so the Claude Projects
/// area can render instantly from the previous scan instead of flashing empty while a
/// fresh scan (which touches the filesystem and git) runs in the background.
struct ClaudeProjectsCache: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = base
                .appendingPathComponent("Jaca", isDirectory: true)
                .appendingPathComponent("claude-projects.json")
        }
    }

    func load() -> [ClaudeProject]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([ClaudeProject].self, from: data)
    }

    func save(_ projects: [ClaudeProject]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
