import Foundation

/// Whether Jaca can obtain root on a device, which decides how the proxy CA gets
/// trusted. Rooted devices (emulators via `adb root`, or physical devices with
/// Magisk `su`) get the CA installed into the **system** store with no on-device
/// UI; everything else falls back to the **user** store via the on-device install
/// dialog.
enum RootStatus: String, Sendable, Equatable, Codable {
    case rooted        // `adb root` works (emulator/userdebug) or `su` is present
    case notRooted     // production `user` build, no su
    case unknown       // couldn't determine (offline mid-probe)
}

/// Static facts about an Android device that decide how we install the proxy CA
/// and which capture modes we can offer. Probed via `adb` **without mutating** the
/// device — we only run `adb root` later, at install time.
struct AndroidCapabilities: Sendable, Equatable, Codable {
    var isEmulator: Bool
    var sdkInt: Int            // ro.build.version.sdk; 0 when unknown
    var abi: String            // ro.product.cpu.abi, e.g. "arm64-v8a"
    var hasScreenLock: Bool    // a PIN/pattern/password is set (CA user-store install needs one)
    var root: RootStatus

    /// API 34+ (Android 14) keeps the trust store in the conscrypt APEX, so a
    /// system-store install needs the tmpfs + `nsenter` bind-mount injection
    /// rather than a plain push into `/system/etc/security/cacerts`.
    var usesApexCACerts: Bool { sdkInt >= 34 }

    /// Can we install the CA into the system store automatically (no on-device UI)?
    var canAutoInstallCA: Bool { root == .rooted }

    static let unknown = AndroidCapabilities(
        isEmulator: false, sdkInt: 0, abi: "", hasScreenLock: false, root: .unknown
    )
}

/// Probes `AndroidCapabilities` over `adb`. Parsing is split out (`parse`) so it
/// can be unit-tested without a device, mirroring `AndroidDeviceParser`.
enum AndroidCapabilityProbe {
    /// Runs the (non-mutating) `adb` queries and assembles capabilities. Returns
    /// `.unknown` if the device can't be reached.
    static func probe(adbURL: URL, serial: String) async -> AndroidCapabilities {
        func getprop(_ key: String) async -> String {
            let r = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "getprop", key])
            return (r?.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // `su 0 id` succeeds on Magisk / already-root adbd; a clean, non-mutating
        // probe (unlike `adb root`, which restarts adbd).
        async let suResult = CommandRunner.run(adbURL, ["-s", serial, "shell", "su", "0", "id"])
        async let lockResult = CommandRunner.run(
            adbURL, ["-s", serial, "shell", "cmd", "lock_settings", "get-disabled"]
        )

        let qemu = await getprop("ro.boot.qemu")
        let kernelQemu = await getprop("ro.kernel.qemu")
        let sdk = await getprop("ro.build.version.sdk")
        let abi = await getprop("ro.product.cpu.abi")
        let buildType = await getprop("ro.build.type")

        let suOut = try? await suResult
        let suOK = suOut?.exitCode == 0 && (suOut?.stdout.contains("uid=0") ?? false)
        let lockDisabled = (try? await lockResult)?.stdout

        // No props at all → we couldn't talk to the device.
        if sdk.isEmpty && abi.isEmpty && buildType.isEmpty && !suOK {
            return .unknown
        }
        return parse(serial: serial, qemu: qemu, kernelQemu: kernelQemu, sdk: sdk,
                     abi: abi, buildType: buildType, suOK: suOK, lockDisabled: lockDisabled)
    }

    /// Pure assembly from raw command outputs (testable).
    static func parse(serial: String, qemu: String, kernelQemu: String, sdk: String,
                      abi: String, buildType: String, suOK: Bool, lockDisabled: String?) -> AndroidCapabilities {
        let isEmulator = serial.hasPrefix("emulator-") || qemu == "1" || kernelQemu == "1"
        // `userdebug`/`eng` builds (all emulator system images except Google-Play)
        // allow `adb root`; `user` builds are production and can't.
        let rootableBuild = buildType == "userdebug" || buildType == "eng"
        let root: RootStatus
        if suOK || rootableBuild { root = .rooted }
        else if buildType.isEmpty { root = .unknown }
        else { root = .notRooted }

        // `get-disabled` prints "true" when there is NO secure lock screen.
        let hasScreenLock = lockDisabled.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "false"
        } ?? false

        return AndroidCapabilities(
            isEmulator: isEmulator,
            sdkInt: Int(sdk) ?? 0,
            abi: abi,
            hasScreenLock: hasScreenLock,
            root: root
        )
    }
}
