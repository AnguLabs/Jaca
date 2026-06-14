import Foundation

/// Persists known companion devices (id + name) so they reappear after a Jaca restart,
/// shown offline until mDNS rediscovers them. Mirrors the on-disk cache pattern used by
/// the other areas.
struct CompanionDeviceStore: Sendable {
    struct Cached: Codable, Hashable, Sendable {
        let id: String
        let name: String
    }

    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = base
                .appendingPathComponent("Jaca", isDirectory: true)
                .appendingPathComponent("companion-devices.json")
        }
    }

    func load() -> [Cached] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Cached].self, from: data)) ?? []
    }

    func save(_ devices: [Cached]) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(devices) { try? data.write(to: fileURL, options: .atomic) }
    }
}
