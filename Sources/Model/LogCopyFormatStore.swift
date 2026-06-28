import Foundation
import Observation

/// App-wide store for the configurable log copy format (⌘C), persisted to `~/.jaca` so it's easy
/// to inspect. One shared instance read by every log list's copy and by the config modal.
@MainActor
@Observable
final class LogCopyFormatStore {
    static let shared = LogCopyFormatStore()

    var format: LogCopyFormat { didSet { persist() } }

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jaca", isDirectory: true)
            .appendingPathComponent("log-copy-format.json")
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode(LogCopyFormat.self, from: data) {
            format = decoded
        } else {
            format = .default
        }
    }

    private func persist() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(format) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
