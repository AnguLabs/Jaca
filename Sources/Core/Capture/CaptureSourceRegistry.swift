import Foundation

/// The registered capture sources. Adding a new way to capture means appending a
/// descriptor here (plus its `CaptureSource` file) — `NetworkSession` and the chooser
/// consume this list generically, so nothing already working changes.
@MainActor
enum CaptureSourceRegistry {
    // Proxy was dropped: only the on-device companion VPN can attribute traffic per app,
    // so companion is the device-wide source. Agent stays for per-app deep-inspection.
    static let all: [CaptureSourceDescriptor] = [companion, agent]

    static let agent = CaptureSourceDescriptor(
        id: "agent", kind: .agent,
        title: "In-process agent",
        detail: "Inspect one debuggable app in-process — no proxy or CA, with call stacks.",
        // Offered for any debuggable-capable Android device. Whether the agent is actually built
        // into the app is checked in the precheck, so a missing agent fails with install steps
        // instead of silently disappearing from the chooser.
        isAvailable: { device, _ in device.platform == .android && !device.isCompanion },
        needsPackage: true,
        precheck: { ctx in await AgentCaptureSource.precheck(device: ctx.device, adbURL: ctx.adbURL, package: ctx.targetPackage) },
        make: { ctx in AgentCaptureSource(adbURL: ctx.adbURL, serial: ctx.device.id, package: ctx.targetPackage ?? "") },
    )

    static let companion = CaptureSourceDescriptor(
        id: "companion", kind: .companion,
        title: "Companion stream",
        detail: "Receive per-app traffic from the Jaca mobile agent over the network.",
        isAvailable: { device, _ in device.companionID != nil },
        needsPackage: false,
        make: { ctx in CompanionCaptureSource(device: ctx.device, hub: ctx.companion ?? CompanionHub(), ca: ctx.ca) },
    )

    /// Options offered for a device, in display order. The companion (device-wide HTTPS
    /// decryption) source is gated behind the experimental feature flag — off by default, so
    /// network inspection offers only the in-process Agent.
    static func options(for device: Device, context: DeviceContext?) -> [CaptureSourceDescriptor] {
        let decryption = FeatureFlags.httpsDecryptionEnabled
        return all.filter { $0.isAvailable(device, context) && (decryption || $0.kind == .agent) }
    }

    static func descriptor(id: String) -> CaptureSourceDescriptor? { all.first { $0.id == id } }

    /// Default option for a device when none is chosen: companion (device-wide) when
    /// available, otherwise the first option (agent).
    static func defaultDescriptor(for device: Device, context: DeviceContext?) -> CaptureSourceDescriptor? {
        let opts = options(for: device, context: context)
        return opts.first { $0.kind == .companion } ?? opts.first
    }
}
