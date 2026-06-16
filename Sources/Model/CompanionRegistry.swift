import Foundation
import Network
import Observation
import os

private let companionLog = Logger(subsystem: "dev.srsouza.jaca", category: "companion")

/// How the desktop reaches a companion. ADB (USB) is the most reliable — it ignores Wi-Fi IP
/// changes, mDNS, and Local Network permission; mDNS depends on the LAN; manual is a
/// remembered IP from QR onboarding.
enum CompanionTransport: String, Sendable { case adb, mdns, manual }

/// Everything the UI needs to know about one companion device, derived in ONE place from the
/// transport layer so no screen re-derives or polls it. `caReady` (HTTPS actually decrypting)
/// stays per-session — that's about a capture tab, not the device link itself.
struct CompanionDeviceState: Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var version: String?
    var transport: CompanionTransport = .mdns
    var reachable: Bool = false    // currently discovered (mDNS / adb / manual)
    var connected: Bool = false    // gRPC control link is up
    var capturing: Bool = false    // on-device VPN capture is running (from the heartbeat)
    var lastHeartbeat: Date?
    var updateAvailable: Bool = false

    /// The coarse lifecycle the UI renders, in one definition instead of per screen.
    enum Phase { case offline, reachable, connected, capturing }
    var phase: Phase {
        if !connected { return reachable ? .reachable : .offline }
        return capturing ? .capturing : .connected
    }
}

/// The single source of truth for companion devices: mDNS discovery, the gRPC control links,
/// the CA push, capture heartbeats, and the "macOS blocked our mDNS" hint — all in one
/// observable place. Views render `devices` / `networkBlocked` directly (no per-screen polling
/// or duplicated validation), and every flow (network sessions, the sidebar, the guided setup)
/// reads the same state. Owns the `CompanionHub` (transport) and persists what it's seen so
/// devices reappear after a restart.
@Observable @MainActor
final class CompanionRegistry {
    /// Transport, owned here. Capture sources still talk to it directly for flow streams.
    let hub = CompanionHub()

    /// One entry per known companion (live or previously-seen-offline), keyed by stable id.
    private(set) var devices: [CompanionDeviceState] = []
    /// macOS is blocking mDNS discovery (Local Network permission) — surfaced as a one-click hint.
    private(set) var networkBlocked = false

    /// Called after any companion state change, so the owner can fold companion devices into
    /// its unified device list. AppModel sets this to `recomputeDevices`.
    var onChange: () -> Void = {}
    /// Whether a companion is "expected" right now (a capture tab is open) — widens the
    /// blocked-network hint beyond "we've seen one before". Set by AppModel.
    var hasOpenCompanionSession: () -> Bool = { false }

    private let store = CompanionDeviceStore()
    private let ca: () -> CertificateAuthority?
    private let adbURL: () -> URL?

    private var known: [CompanionDeviceStore.Cached] = []   // persisted, shown offline until seen
    private var live: [String: CompanionDevice] = [:]       // currently discovered, with endpoint
    private var versions: [String: String] = [:]
    private var heartbeats: [String: Date] = [:]
    private var caPushed: Set<String> = []
    private var browseFailed = false
    private var graceElapsed = false
    private var started = false
    private var livenessTask: Task<Void, Never>?

    /// adb-connected Android devices used as an mDNS fallback: serial -> model, and the serials
    /// we've opened a network link for (`adb:<serial>`). adb only supplies the phone's IP; the
    /// link is a normal gRPC connection over the network.
    private var adbDevices: [String: String] = [:]
    private var adbLinked: Set<String> = []

    init(ca: @escaping () -> CertificateAuthority?, adbURL: @escaping () -> URL?, uiTestMode: Bool = false) {
        self.ca = ca
        self.adbURL = adbURL
        // Drop legacy address-keyed entries so stale IP/endpoint companions don't linger.
        if !uiTestMode { known = store.load().filter { Self.isDeviceID($0.id) } }
        wireHub()
        rebuild()
    }

    /// Begin discovery (mDNS browse) and liveness checks. Idempotent; called only when the
    /// experimental HTTPS-decryption feature is on.
    func start() {
        guard !started else { return }
        started = true
        hub.startBrowsing()
        // After a grace window, if nothing turned up for a companion we'd expect, surface the
        // Local Network hint (covers macOS leaving the browse .ready but silently empty).
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self else { return }
            self.graceElapsed = true
            self.refreshBlocked()
        }
        startLiveness()
    }

    /// Tear everything down when the feature flag is turned off: stop discovery + liveness,
    /// disconnect every link, and clear state so nothing keeps running in the background.
    func stop() {
        guard started else { return }
        started = false
        livenessTask?.cancel()
        livenessTask = nil
        hub.stopBrowsing()
        for id in Set(devices.map(\.id) + adbLinked.map { "adb:" + $0 }) { hub.disconnect(id: id) }
        live = [:]; adbDevices = [:]; adbLinked = []
        versions = [:]; heartbeats = [:]; caPushed = []
        graceElapsed = false; browseFailed = false; networkBlocked = false
        rebuild()
    }

    /// Detect a silently-dropped link: when the phone changes Wi-Fi/IP the gRPC channel can
    /// half-open and stop delivering while still reporting "connected". The phone sends a
    /// heartbeat every ~2s over the stream, so if a connected companion goes quiet for 6s we
    /// recover it — re-querying the IP over adb (for the adb fallback, which is how the desktop
    /// finds a moved phone) or reconnecting to its latest mDNS address.
    private func startLiveness() {
        livenessTask?.cancel()
        livenessTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                let now = Date()
                for d in self.devices where d.connected {
                    guard let last = d.lastHeartbeat, now.timeIntervalSince(last) > 6 else { continue }
                    if d.transport == .adb, d.id.hasPrefix("adb:") {
                        self.discoverAndConnect(String(d.id.dropFirst(4)))
                    } else {
                        self.hub.reconnect(id: d.id)
                    }
                }
            }
        }
    }

    // MARK: - Queries (read by every flow; all reactive via `devices`)

    func state(for id: String) -> CompanionDeviceState? { devices.first { $0.id == id } }

    // MARK: - Actions

    func connect(_ id: String) { hub.connect(id: id) }
    func rememberManual(host: String) { hub.rememberManual(host: host) }

    // MARK: - ADB IP discovery (FALLBACK only — adb finds the IP, then we talk over the network)

    /// The currently adb-connected Android devices (serial + model). adb is used ONLY to learn
    /// the phone's current LAN IP when mDNS can't see it (permission blocked, or it hasn't
    /// re-announced after an IP change); the link itself is a normal gRPC connection over the
    /// network — never a USB tunnel. Re-reconciled whenever the adb or mDNS device set changes.
    func setADBCompanionDevices(_ devices: [(serial: String, model: String)]) {
        // Emulators sit behind NAT — their `ip addr` is the unreachable 10.0.2.x, so they can't
        // be reached by IP over the network and aren't adb-IP-discovery candidates.
        adbDevices = Dictionary(devices.filter { !$0.serial.hasPrefix("emulator-") }.map { ($0.serial, $0.model) },
                                uniquingKeysWith: { a, _ in a })
        reconcileADB()
    }

    /// Open a network link (at the adb-discovered IP) for each adb device mDNS ISN'T already
    /// covering; drop links for devices that left or that mDNS now covers (so adb is a pure
    /// fallback and we never double-connect to a phone mDNS already found).
    private func reconcileADB() {
        for (serial, model) in adbDevices where !adbLinked.contains(serial) && !mdnsCovers(model) {
            adbLinked.insert(serial)
            discoverAndConnect(serial)
        }
        for serial in adbLinked where adbDevices[serial] == nil || mdnsCovers(adbDevices[serial] ?? "") {
            adbLinked.remove(serial)
            hub.disconnect(id: "adb:" + serial)
        }
        rebuild()
    }

    /// Ask adb for the phone's LAN IP, then connect the companion gRPC to it over the network.
    private func discoverAndConnect(_ serial: String) {
        guard let adb = adbURL() else { return }
        Task { @MainActor [weak self] in
            let out = try? await CommandRunner.run(adb, ["-s", serial, "shell", "ip", "-o", "-f", "inet", "addr", "show"]).stdout
            guard let self, self.adbLinked.contains(serial), let ip = out.flatMap(Self.parseLanIP) else { return }
            companionLog.info("adb device \(serial, privacy: .public) at \(ip, privacy: .public); connecting over the network")
            self.hub.reconnect(id: "adb:" + serial, host: ip, port: 8889)   // (re)dial the current IP
            self.rebuild()
        }
    }

    /// True when a live mDNS device's name matches this adb device's model (same phone).
    private func mdnsCovers(_ model: String) -> Bool {
        let m = Self.normalizedModel(model)
        return !m.isEmpty && live.values.contains { Self.normalizedModel($0.name) == m }
    }

    /// The phone's LAN IPv4 from `ip -o -f inet addr show`, skipping loopback, the VPN tun, and
    /// cellular — the same interfaces the phone itself excludes when it reports its address.
    static func parseLanIP(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let inetIdx = tokens.firstIndex(of: "inet"), inetIdx + 1 < tokens.count else { continue }
            let ifname = tokens.count > 1 ? tokens[1] : ""
            if ifname == "lo" || ifname.hasPrefix("tun") || ifname.hasPrefix("rmnet")
                || ifname.hasPrefix("ppp") || ifname.hasPrefix("dummy") { continue }
            let ip = tokens[inetIdx + 1].split(separator: "/").first.map(String.init) ?? ""
            if isSiteLocalIPv4(ip) { return ip }
        }
        return nil
    }

    static func isSiteLocalIPv4(_ ip: String) -> Bool {
        if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") { return true }
        if ip.hasPrefix("172.") {
            let second = ip.split(separator: ".").dropFirst().first.flatMap { Int($0) } ?? 0
            return (16...31).contains(second)
        }
        return false
    }

    static func normalizedModel(_ s: String) -> String {
        s.replacingOccurrences(of: "Jaca", with: "").lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Hub wiring (the registry is the hub's only delegate)

    private func wireHub() {
        hub.onDevices = { [weak self] devices in
            guard let self else { return }
            self.live = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            self.persistKnown(devices)
            // Keep a control link to every discovered companion, even before capture, so the
            // desktop can configure it and push its CA. Idempotent; re-resolves on a new IP.
            for d in devices { self.hub.connect(id: d.id, to: d.endpoint) }
            self.refreshBlocked()   // discovering a device clears the "blocked" hint
            self.reconcileADB()     // mDNS coverage changed → adjust the adb fallback (rebuilds)
        }
        hub.onConnectionChange = { [weak self] id, connected in
            guard let self else { return }
            companionLog.info("companion \(id, privacy: .public) \(connected ? "connected" : "disconnected", privacy: .public)")
            if connected {
                self.pushCA(id)             // give the app the cert to install, pre-capture
            } else {
                self.caPushed.remove(id)    // re-push on reconnect (the app may have restarted)
                self.heartbeats[id] = nil
            }
            self.rebuild()
        }
        hub.onDeviceInfo = { [weak self] id, _, version in
            guard let self else { return }
            self.versions[id] = version
            self.rebuild()
        }
        hub.onCaptureState = { [weak self] id, _ in
            guard let self else { return }
            self.heartbeats[id] = Date()    // any heartbeat is liveness, capturing or not
            self.rebuild()
        }
        hub.onBrowseBlocked = { [weak self] blocked in
            guard let self else { return }
            self.browseFailed = blocked
            self.refreshBlocked()
        }
    }

    /// Recompute `devices` from live + known + the connection/heartbeat/version overlays. One
    /// place, so the UI never re-derives. Cheap; called on any input change.
    private func rebuild() {
        var byID: [String: CompanionDeviceState] = [:]
        for k in known {
            byID[k.id] = CompanionDeviceState(id: k.id, name: k.name)
        }
        for (id, d) in live {
            var s = byID[id] ?? CompanionDeviceState(id: id, name: d.name)
            s.name = d.name
            s.reachable = true
            byID[id] = s
        }
        // adb-fallback links (network, at the adb-discovered IP). The UI gates annotation on
        // `connected`, so an adb device with no companion answering stays invisible.
        for serial in adbLinked {
            let id = "adb:" + serial
            var s = byID[id] ?? CompanionDeviceState(id: id, name: adbDevices[serial] ?? serial)
            s.transport = .adb
            s.reachable = true
            byID[id] = s
        }
        for id in byID.keys {
            byID[id]?.connected = hub.connected.contains(id)
            byID[id]?.capturing = hub.capturing.contains(id)
            byID[id]?.version = versions[id]
            byID[id]?.lastHeartbeat = heartbeats[id]
            byID[id]?.updateAvailable = versions[id].map { CompanionVersion.updateAvailable(deviceVersion: $0) } ?? false
        }
        devices = byID.values.sorted { $0.name < $1.name }
        onChange()
    }

    /// Push the desktop CA to a freshly connected companion so the app can prompt the user to
    /// install it — once per connection, before any capture.
    private func pushCA(_ id: String) {
        guard !caPushed.contains(id), let ca = ca() else { return }
        caPushed.insert(id)
        hub.installCa(id: id, pem: Data(ca.rootCertificatePEM.utf8))
    }

    private func persistKnown(_ liveDevices: [CompanionDevice]) {
        var byID = Dictionary(uniqueKeysWithValues: known.map { ($0.id, $0) })
        // Only remember devices by their stable id (the UUID the app advertises) — never by a
        // transient address — so a device stays one entry across reconnects and IP changes.
        for d in liveDevices where Self.isDeviceID(d.id) {
            byID[d.id] = CompanionDeviceStore.Cached(id: d.id, name: d.name)
        }
        known = Array(byID.values)
        store.save(known)
    }

    /// Likely-blocked when the browser failed outright, OR when discovery turned up no live
    /// companion within the grace window despite one being expected (macOS can leave the browse
    /// .ready while silently returning nothing when permission is missing).
    private func refreshBlocked() {
        let intent = !known.isEmpty || hasOpenCompanionSession()
        networkBlocked = browseFailed || (graceElapsed && live.isEmpty && intent)
    }

    /// A stable per-install device id (the UUID the companion advertises in its TXT record),
    /// vs a transient address-based id (an mDNS endpoint string or "host:port").
    static func isDeviceID(_ id: String) -> Bool {
        id.count == 36 && id.filter { $0 == "-" }.count == 4
    }
}
