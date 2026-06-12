import Foundation

/// Disk cache for request/response bodies of older network transactions, so a
/// long-running session keeps the heavy payloads on disk (not RAM) while the list
/// keeps only lightweight metadata in memory. Ephemeral — wiped on launch.
actor NetworkBodyCache {
    private let dir: URL
    private let fm = FileManager.default

    init?() {
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        dir = caches.appendingPathComponent("Jaca/net-bodies", isDirectory: true)
        try? fm.removeItem(at: dir)   // a body cache only needs to outlive the current run
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return nil }
    }

    private struct Blob: Codable { var req: Data?; var resp: Data? }

    /// Persists a transaction's bodies; no-op if both are empty.
    func save(_ id: UUID, req: Data?, resp: Data?) {
        guard req != nil || resp != nil else { return }
        if let data = try? PropertyListEncoder().encode(Blob(req: req, resp: resp)) {
            try? data.write(to: url(id), options: .atomic)
        }
    }

    func load(_ id: UUID) -> (req: Data?, resp: Data?) {
        guard let data = try? Data(contentsOf: url(id)),
              let blob = try? PropertyListDecoder().decode(Blob.self, from: data) else { return (nil, nil) }
        return (blob.req, blob.resp)
    }

    private func url(_ id: UUID) -> URL { dir.appendingPathComponent(id.uuidString) }
}
