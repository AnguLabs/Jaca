import Foundation

/// An installed app/package available to filter by.
struct AppEntry: Identifiable, Hashable, Sendable, Codable {
    let id: String          // package id (Android) / bundle id (iOS)
    let name: String?       // human name (iOS); nil on Android
    let isUserApp: Bool     // user-installed vs system
    var display: String { name ?? id }
}

/// Disk cache of the last good iOS-device app list, so a slow/wedged `devicectl`
/// (CoreDevice stalls) shows the last-known apps instead of an empty "No apps found".
private enum IOSAppCache {
    private static func file(_ udid: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jaca", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ios-apps-\(udid).json")
    }
    static func load(_ udid: String) -> [AppEntry] {
        guard let data = try? Data(contentsOf: file(udid)) else { return [] }
        return (try? JSONDecoder().decode([AppEntry].self, from: data)) ?? []
    }
    static func save(_ apps: [AppEntry], udid: String) {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        try? data.write(to: file(udid))
    }
}

/// Enumerates installed apps for the package/app-id filter dropdown.
enum InstalledApps {
    static func list(for device: Device, adbURL: URL?) async -> [AppEntry] {
        switch device.platform {
        case .android:      return await android(adbURL: adbURL, serial: device.id)
        case .iosSimulator: return await simulator(udid: device.id)
        case .iosDevice:    return await iosDevice(udid: device.id)
        }
    }

    /// Last good list for a device, read synchronously, so UI can show it instantly
    /// while `list(for:)` refreshes. Empty for non-iOS-device or no cache yet.
    static func cached(for device: Device) -> [AppEntry] {
        device.platform == .iosDevice ? IOSAppCache.load(device.id) : []
    }

    // MARK: Android

    private static func android(adbURL: URL?, serial: String) async -> [AppEntry] {
        guard let adbURL else { return [] }
        async let allOut = CommandRunner.run(adbURL, ["-s", serial, "shell", "pm", "list", "packages"])
        async let userOut = CommandRunner.run(adbURL, ["-s", serial, "shell", "pm", "list", "packages", "-3"])
        let all = (try? await allOut)?.stdout ?? ""
        let user = (try? await userOut)?.stdout ?? ""
        return AndroidPackageParser.parse(all: all, userOnly: user)
    }

    // MARK: iOS Simulator

    private static func simulator(udid: String) async -> [AppEntry] {
        guard AppleToolchain.hasFullXcode,
              let result = try? await CommandRunner.run(
                AppleToolchain.xcrun, ["simctl", "listapps", udid],
                environment: AppleToolchain.environment()
              ) else { return [] }
        return SimulatorAppsParser.parse(Data(result.stdout.utf8))
    }

    // MARK: iOS Device

    private static func iosDevice(udid: String) async -> [AppEntry] {
        guard AppleToolchain.hasFullXcode else { return IOSAppCache.load(udid) }
        // devicectl's first call after a cold start often stalls while it warms the device
        // tunnel, then a retry returns fast — so try twice before giving up. On any
        // slow/empty/failed result, fall back to the last good list so the picker never
        // blanks to "No apps found".
        for attempt in 0..<2 {
            if let fresh = await queryIOSApps(udid: udid), !fresh.isEmpty {
                IOSAppCache.save(fresh, udid: udid)
                return fresh
            }
            if attempt == 0 { try? await Task.sleep(for: .seconds(1)) }
        }
        return IOSAppCache.load(udid)
    }

    private static func queryIOSApps(udid: String) async -> [AppEntry]? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jaca-devicectl-apps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? await CommandRunner.run(
            AppleToolchain.xcrun,
            ["devicectl", "device", "info", "apps", "--device", udid, "--json-output", tmp.path],
            environment: AppleToolchain.environment(),
            timeout: 20
        )) != nil, let data = try? Data(contentsOf: tmp) else { return nil }
        return IOSAppsParser.parse(data)
    }
}

/// Parses `devicectl device info apps --json-output` into app entries.
/// devicectl lists only user-installed apps by default, so the list is already
/// scoped to what you'd want to filter by.
enum IOSAppsParser {
    static func parse(_ data: Data) -> [AppEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let result = root["result"] as? [String: Any]
        let list = (result?["apps"] as? [[String: Any]]) ?? (root["apps"] as? [[String: Any]]) ?? []

        var seen = Set<String>()
        var entries: [AppEntry] = []
        for app in list {
            guard let id = app["bundleIdentifier"] as? String, !id.isEmpty,
                  seen.insert(id).inserted else { continue }
            let name = app["name"] as? String
            // Removable apps are user-installed; built-in/system apps aren't.
            let isUser = (app["removable"] as? Bool) ?? true
            entries.append(AppEntry(id: id, name: name, isUserApp: isUser))
        }
        return sortUserFirst(entries)
    }
}

/// Parses `pm list packages` output (lines like `package:com.foo`).
enum AndroidPackageParser {
    static func parse(all: String, userOnly: String) -> [AppEntry] {
        func ids(_ text: String) -> [String] {
            text.split(separator: "\n").compactMap { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("package:") else { return nil }
                let id = String(t.dropFirst("package:".count)).trimmingCharacters(in: .whitespaces)
                return id.isEmpty ? nil : id
            }
        }
        let userSet = Set(ids(userOnly))
        let entries = ids(all).map { AppEntry(id: $0, name: nil, isUserApp: userSet.contains($0)) }
        return sortUserFirst(entries)
    }
}

/// Parses `simctl listapps` (OpenStep plist) into app entries.
enum SimulatorAppsParser {
    static func parse(_ data: Data) -> [AppEntry] {
        if let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            var entries: [AppEntry] = []
            for (key, value) in root {
                guard let dict = value as? [String: Any] else { continue }
                let id = (dict["CFBundleIdentifier"] as? String) ?? key
                let name = (dict["CFBundleDisplayName"] as? String) ?? (dict["CFBundleName"] as? String)
                let type = (dict["ApplicationType"] as? String) ?? ""
                entries.append(AppEntry(id: id, name: name, isUserApp: type == "User"))
            }
            if !entries.isEmpty { return sortUserFirst(entries) }
        }
        return regexFallback(String(decoding: data, as: UTF8.self))
    }

    /// Defensive fallback if plist parsing fails: scrape bundle ids.
    private static func regexFallback(_ text: String) -> [AppEntry] {
        let pattern = #"CFBundleIdentifier\s*=\s*"?([\w.\-]+)"?\s*;"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var entries: [AppEntry] = []
        for m in rx.matches(in: text, range: range) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let id = String(text[r])
            if seen.insert(id).inserted {
                entries.append(AppEntry(id: id, name: nil, isUserApp: !id.hasPrefix("com.apple.")))
            }
        }
        return sortUserFirst(entries)
    }
}

/// User apps first, then alphabetical by display name.
private func sortUserFirst(_ entries: [AppEntry]) -> [AppEntry] {
    entries.sorted {
        if $0.isUserApp != $1.isUserApp { return $0.isUserApp && !$1.isUserApp }
        return $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending
    }
}
