import Foundation
import Observation

/// Drives the "Pair device over Wi-Fi" sheet. A small state machine over the two
/// Android pairing flows plus a live mDNS discovery loop:
///
///   • QR mode — we generate a service name + password, render a QR, then watch mDNS
///     for the phone to start advertising `_adb-tls-pairing._tcp` under *our* service
///     name (which means it scanned the QR). The moment it appears we auto-pair.
///   • Code mode — the phone shows a 6-digit code and its `ip:port`. The user either
///     picks the device from the discovered list or types the `ip:port` (the bullet-
///     proof fallback when mDNS is blocked), enters the code, and pairs.
///
/// Throughout we surface adb's mDNS health and offer a one-click `adb kill-server`
/// recovery, because a wedged mDNS daemon is the usual reason a device "never shows up".
@MainActor
@Observable
final class PairingModel: Identifiable {
    /// Stable identity so the sheet can present via `.sheet(item:)` (which guarantees
    /// a non-nil model in its content — avoids the empty-dialog race that `isPresented`
    /// + `if let` suffered).
    let id = UUID()

    enum Mode: String, CaseIterable, Identifiable { case qr, code; var id: String { rawValue } }

    enum Status: Equatable {
        case idle
        case waitingForScan        // QR shown; waiting for the phone to advertise
        case pairing               // `adb pair` in flight
        case paired(name: String)  // success
        case failed(String)        // adb failure, message kept for the user
    }

    var mode: Mode = .qr { didSet { if mode != oldValue { onModeChange() } } }
    private(set) var status: Status = .idle

    // QR mode
    private(set) var credentials: QrPairingCredentials?
    var qrPayload: String? { credentials?.qrPayload }

    // Live discovery
    private(set) var pairingServices: [MdnsService] = []   // `_adb-tls-pairing._tcp` only
    private(set) var mdnsHealth: MdnsHealth = .unknown("")
    private(set) var recovering = false

    // Code-mode inputs
    var selectedServiceID: String?
    var manualAddress = ""      // ip:port typed from the phone screen
    var pairingCode = ""

    private let service: AdbPairingService?
    private var discoveryTask: Task<Void, Never>?
    private var pollTick = 0

    /// nil `adbURL` means the toolchain is missing — the sheet shows the adb notice.
    init(adbURL: URL?) {
        service = adbURL.map { AdbPairingService(adbURL: $0) }
        // Generate the QR eagerly so it's on screen the instant the sheet opens, with
        // no blank first frame waiting on `.task`.
        credentials = .generate()
        status = .waitingForScan
    }

    var adbAvailable: Bool { service != nil }

    // MARK: - Lifecycle (called from the sheet's .task / onDisappear)

    func start() {
        if mode == .qr, credentials == nil { regenerateQR() }
        if mode == .qr { status = .waitingForScan }
        startDiscovery()
    }

    func stop() {
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    private func onModeChange() {
        // Reset transient state when flipping tabs; keep discovery running.
        switch mode {
        case .qr:
            if credentials == nil { regenerateQR() }
            status = .waitingForScan
        case .code:
            status = .idle
        }
    }

    func regenerateQR() {
        credentials = .generate()
        status = .waitingForScan
    }

    /// Back to a fresh state after a success/failure so the user can pair again.
    func reset() {
        pairingCode = ""
        if mode == .qr { regenerateQR() } else { status = .idle }
    }

    // MARK: - Discovery loop

    private func startDiscovery() {
        guard discoveryTask == nil, let service else { return }
        // The Task inherits @MainActor isolation, so property writes are safe; each
        // `await` hops off the main actor to run adb and back. Capture `self` weakly so
        // dismissing the sheet (which cancels the task) lets the model deallocate.
        discoveryTask = Task { [weak self, service] in
            while !Task.isCancelled {
                let services = await service.discoverServices()
                // mDNS health spawns a process; check it every 4th poll, not every second.
                let needHealth = ((self?.pollTick ?? 0) % 4 == 0)
                let health: MdnsHealth? = needHealth ? await service.mdnsCheck() : nil
                guard let self, !Task.isCancelled else { return }
                self.pairingServices = services.filter { $0.kind == .pairing }
                if let health { self.mdnsHealth = health }
                self.pollTick &+= 1
                self.maybeAutoPairFromQR()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// In QR mode, the phone advertises a pairing service whose instance name equals
    /// the service name we put in the QR. Spotting it means "the QR was scanned" — pair.
    private func maybeAutoPairFromQR() {
        guard mode == .qr, case .waitingForScan = status,
              let serviceName = credentials?.serviceName,
              let match = pairingServices.first(where: { $0.instance == serviceName }) else { return }
        pairWithQR(address: match.address)
    }

    // MARK: - Pairing

    private func pairWithQR(address: String) {
        guard let service, let creds = credentials else { return }
        status = .pairing
        Task { [weak self] in
            let result = await service.pair(address: address, code: creds.password)
            self?.handle(result, method: .qrCode)
        }
    }

    func pairWithCode() {
        guard let service else { return }
        let address = resolvedCodeAddress()
        let code = pairingCode.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else {
            status = .failed("Select your device or type the IP:port shown on its screen.")
            return
        }
        guard !code.isEmpty else {
            status = .failed("Enter the 6-digit pairing code shown on your device.")
            return
        }
        status = .pairing
        Task { [weak self] in
            let result = await service.pair(address: address, code: code)
            self?.handle(result, method: .pairingCode)
        }
    }

    /// The address to pair against in code mode: the picked discovered service, else
    /// the manually-typed `ip:port`.
    private func resolvedCodeAddress() -> String {
        if let id = selectedServiceID, let svc = pairingServices.first(where: { $0.id == id }) {
            return svc.address
        }
        return manualAddress.trimmingCharacters(in: .whitespaces)
    }

    private func handle(_ result: PairResult, method: PairingMethod) {
        guard result.success else {
            status = .failed(result.message)
            return
        }
        let guid = result.guid ?? result.address ?? "device"
        let name = Self.friendlyName(guid: guid, address: result.address)
        status = .paired(name: name)
        Task {
            await PairedDeviceStore.shared.remember(
                guid: guid, name: name, address: result.address, method: method
            )
        }
    }

    /// adb GUIDs look like "adb-<serial>-<rand>"; show the serial as a hint until the
    /// device connects and the provider supplies the real model name.
    static func friendlyName(guid: String, address: String?) -> String {
        if guid.hasPrefix("adb-") {
            let parts = guid.dropFirst(4).split(separator: "-")
            if let serial = parts.first, !serial.isEmpty { return String(serial) }
        }
        return address ?? guid
    }

    // MARK: - Recovery

    /// Restart the adb server to clear a disabled/wedged mDNS daemon, then re-check.
    func recoverMdns() {
        guard let service, !recovering else { return }
        recovering = true
        Task { [weak self] in
            await service.restartServer()
            let health = await service.mdnsCheck()
            self?.mdnsHealth = health
            self?.recovering = false
        }
    }
}
