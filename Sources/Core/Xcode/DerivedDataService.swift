import Foundation

/// Lists and deletes entries under `~/Library/Developer/Xcode/DerivedData`.
/// Each project entry's `info.plist` carries a `WorkspacePath`; when that path no
/// longer exists the entry is stale (e.g. a worktree that was removed). Shared
/// caches (`*.noindex`) have no `WorkspacePath` and are reported separately.
struct DerivedDataService: Sendable {
    private var derivedDataDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }

    /// Snapshots every DerivedData folder with its size and kind.
    /// Sorted stale-first, then shared, then live; within each group largest-first.
    /// (`du` is slow on big caches, so this is computed on demand, not polled.)
    func list() async -> [DerivedDataEntry] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: derivedDataDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var entries: [DerivedDataEntry] = []
        for dir in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let sizeMB = await duKB(dir.path) / 1024

            if let ws = workspacePath(in: dir) {
                let exists = fm.fileExists(atPath: ws)
                entries.append(DerivedDataEntry(
                    name: projectName(fromWorkspace: ws),
                    path: dir.path,
                    workspacePath: ws,
                    sizeMB: sizeMB,
                    kind: exists ? .live : .stale
                ))
            } else {
                entries.append(DerivedDataEntry(
                    name: sharedName(dir.lastPathComponent),
                    path: dir.path,
                    workspacePath: nil,
                    sizeMB: sizeMB,
                    kind: .shared
                ))
            }
        }
        return entries.sorted { a, b in
            rank(a.kind) != rank(b.kind) ? rank(a.kind) < rank(b.kind) : a.sizeMB > b.sizeMB
        }
    }

    /// Deletes a DerivedData subfolder. Returns true on success.
    func delete(path: String) async -> Bool {
        do { try FileManager.default.removeItem(atPath: path); return true }
        catch { return false }
    }

    // MARK: - Helpers

    private func rank(_ kind: DerivedDataKind) -> Int {
        switch kind {
        case .stale: return 0
        case .shared: return 1
        case .live: return 2
        }
    }

    /// Reads `WorkspacePath` from a DerivedData entry's `info.plist`, or nil (shared cache).
    private func workspacePath(in dir: URL) -> String? {
        let plist = dir.appendingPathComponent("info.plist")
        guard let data = try? Data(contentsOf: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any],
              let ws = dict["WorkspacePath"] as? String else { return nil }
        return ws
    }

    /// "/…/MyApp/MyApp.xcodeproj" → "MyApp".
    private func projectName(fromWorkspace ws: String) -> String {
        (ws as NSString).lastPathComponent
            .replacingOccurrences(of: ".xcodeproj", with: "")
            .replacingOccurrences(of: ".xcworkspace", with: "")
    }

    /// "ModuleCache.noindex" → "ModuleCache".
    private func sharedName(_ folder: String) -> String {
        folder.replacingOccurrences(of: ".noindex", with: "")
    }

    private func duKB(_ path: String) async -> Int {
        guard let r = try? await CommandRunner.run(URL(fileURLWithPath: "/usr/bin/du"), ["-sk", path]) else { return 0 }
        let first = r.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).first
        return Int(first ?? "") ?? 0
    }
}
