import Foundation

/// How a device was paired. Surfaced in the UI and remembered so a re-pair offers
/// the method that worked last time.
enum PairingMethod: String, Codable, Sendable {
    case qrCode
    case pairingCode

    var label: String {
        switch self {
        case .qrCode: return "QR code"
        case .pairingCode: return "Pairing code"
        }
    }
}

/// A device Jaca has paired with before. adb's own `adb_known_hosts.pb` stores only
/// a bare GUID — no name, no last-seen, no way to say *why* a remembered device isn't
/// here right now. We store the richer record so the UI can say "Pixel 8 — paired 3
/// days ago, not on this network" instead of nothing, and so we can proactively
/// reconnect it when its `_adb-tls-connect` service reappears.
struct PairedDevice: Codable, Identifiable, Sendable, Hashable {
    /// mDNS instance name == device GUID (e.g. "adb-939AX05XBZ-vWgJpq"). Stable across
    /// reconnects and IP changes; the join key against discovered connect services.
    var guid: String
    var name: String
    /// Last `ip:port` we saw its `_adb-tls-connect` service at (for a targeted reconnect).
    var lastAddress: String?
    var method: PairingMethod
    var firstPairedAt: Date
    var lastSeenAt: Date

    var id: String { guid }
}

/// JSON-backed persistence of paired devices under Application Support/Jaca, plus the
/// reconciliation logic that makes reconnect "just work". Actor-isolated; file IO is
/// small and serialized.
actor PairedDeviceStore {
    static let shared = PairedDeviceStore()

    private let fileURL: URL
    private var devices: [String: PairedDevice] = [:]
    private var loaded = false

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Jaca", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.fileURL = base.appendingPathComponent("paired-devices.json")
        }
    }

    func all() -> [PairedDevice] {
        load()
        return devices.values.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    /// Upserts a freshly-paired device, stamping it as seen now.
    func remember(guid: String, name: String, address: String?, method: PairingMethod, now: Date = Date()) {
        load()
        if var existing = devices[guid] {
            existing.name = name.isEmpty ? existing.name : name
            existing.lastAddress = address ?? existing.lastAddress
            existing.method = method
            existing.lastSeenAt = now
            devices[guid] = existing
        } else {
            devices[guid] = PairedDevice(
                guid: guid, name: name, lastAddress: address,
                method: method, firstPairedAt: now, lastSeenAt: now
            )
        }
        save()
    }

    /// Records that a known device was just observed (over mDNS or `adb devices`).
    func markSeen(guid: String, address: String?, now: Date = Date()) {
        load()
        guard var device = devices[guid] else { return }
        device.lastSeenAt = now
        if let address { device.lastAddress = address }
        devices[guid] = device
        save()
    }

    func forget(guid: String) {
        load()
        devices.removeValue(forKey: guid)
        save()
    }

    /// Given the connect services adb currently sees over mDNS, return the addresses of
    /// *known* devices so the caller can `adb connect` any that aren't attached yet.
    /// Updates last-seen as a side effect. This is the "auto-recover" core: adb doesn't
    /// always reattach a paired device on its own, so we nudge it.
    func reconnectTargets(from services: [MdnsService], now: Date = Date()) -> [(guid: String, address: String)] {
        load()
        var targets: [(String, String)] = []
        for service in services where service.kind == .connect {
            guard var device = devices[service.instance] else { continue }
            device.lastSeenAt = now
            device.lastAddress = service.address
            devices[service.instance] = device
            targets.append((service.instance, service.address))
        }
        if !targets.isEmpty { save() }
        return targets
    }

    // MARK: - Disk

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder.iso8601.decode([PairedDevice].self, from: data) else { return }
        devices = Dictionary(uniqueKeysWithValues: list.map { ($0.guid, $0) })
    }

    private func save() {
        guard let data = try? JSONEncoder.iso8601.encode(Array(devices.values)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
}
