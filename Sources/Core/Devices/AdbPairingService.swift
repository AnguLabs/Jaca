import Foundation

/// Outcome of `adb pair`. adb prints, on success:
///   `Successfully paired to 192.168.1.174:40711 [guid=adb-43081FDAS000ST-GIVKML]`
/// and on failure a `Failed: …` line (wrong code, dropped connection, no client).
/// We keep the raw text for diagnostics — surfacing *why* it failed is the whole
/// point of doing better than Studio's silent failures.
struct PairResult: Sendable, Equatable {
    let success: Bool
    let guid: String?
    let address: String?
    let message: String

    /// Pure parser over adb's combined output, so it can be unit-tested without adb.
    static func parse(stdout: String, stderr: String, exitCode: Int32) -> PairResult {
        let text = (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = successRegex.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)
        ), let addrRange = Range(match.range(at: 1), in: text),
           let guidRange = Range(match.range(at: 2), in: text) {
            return PairResult(
                success: true,
                guid: String(text[guidRange]),
                address: String(text[addrRange]),
                message: text
            )
        }
        // Some adb builds print "Successfully paired" without a guid; treat as success.
        if exitCode == 0, text.localizedCaseInsensitiveContains("successfully paired") {
            return PairResult(success: true, guid: nil, address: nil, message: text)
        }
        let message = text.isEmpty ? "Pairing failed (no output from adb)." : text
        return PairResult(success: false, guid: nil, address: nil, message: message)
    }

    // "Successfully paired to <addr> [guid=<guid>]"
    private static let successRegex = try! NSRegularExpression(
        pattern: #"Successfully paired to (.+?) \[guid=([^\]]*)\]"#
    )
}

/// State of the adb server's mDNS subsystem, from `adb mdns check`. A disabled or
/// stale mDNS daemon is the #1 reason wireless devices silently never appear, so we
/// detect it and offer a one-click `adb kill-server` recovery.
enum MdnsHealth: Sendable, Equatable {
    case ok(backend: String)   // e.g. "Openscreen discovery 0.0.0" / "Bonjour"
    case disabled(String)      // adb reports mdns unavailable/disabled
    case unknown(String)       // couldn't classify (raw text kept)

    var isHealthy: Bool { if case .ok = self { return true }; return false }

    static func parse(stdout: String, stderr: String) -> MdnsHealth {
        let text = (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("error") || lower.contains("unavailable") || lower.contains("disabled") {
            return .disabled(text)
        }
        // "mdns daemon version [Openscreen discovery 0.0.0]"
        if let open = text.range(of: "["), let close = text.range(of: "]", options: .backwards),
           open.upperBound <= close.lowerBound {
            let backend = String(text[open.upperBound..<close.lowerBound])
            return backend.isEmpty || backend.lowercased().contains("unknown")
                ? .disabled(text)
                : .ok(backend: backend)
        }
        return text.isEmpty ? .unknown("no output") : .unknown(text)
    }
}

/// Thin async wrapper around the `adb` CLI for wireless pairing + reconnection.
/// Mirrors `AndroidDeviceProvider`'s use of `CommandRunner`; holds no state beyond
/// the resolved adb path, so it's cheap to construct per call.
struct AdbPairingService: Sendable {
    let adbURL: URL

    /// `adb mdns services` → discovered pairing/connect/legacy services.
    func discoverServices() async -> [MdnsService] {
        guard let result = try? await CommandRunner.run(adbURL, ["mdns", "services"]) else { return [] }
        return MdnsServiceParser.parse(result.stdout)
    }

    /// `adb mdns check` → health of the adb server's mDNS discovery.
    func mdnsCheck() async -> MdnsHealth {
        guard let result = try? await CommandRunner.run(adbURL, ["mdns", "check"]) else {
            return .unknown("adb did not run")
        }
        return MdnsHealth.parse(stdout: result.stdout, stderr: result.stderr)
    }

    /// `adb pair <host:port> <code>`. The code is passed as an argument so adb never
    /// prompts on stdin (which would hang us).
    func pair(address: String, code: String) async -> PairResult {
        guard let result = try? await CommandRunner.run(adbURL, ["pair", address, code]) else {
            return PairResult(success: false, guid: nil, address: address,
                              message: "Could not launch adb.")
        }
        return PairResult.parse(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }

    /// `adb connect <host:port>` — used to (re)attach an already-paired device whose
    /// `_adb-tls-connect` service we found over mDNS. Returns true on apparent success.
    @discardableResult
    func connect(address: String) async -> Bool {
        guard let result = try? await CommandRunner.run(adbURL, ["connect", address]) else { return false }
        let text = (result.stdout + result.stderr).lowercased()
        // adb prints "connected to …" / "already connected …" on success,
        // "failed to connect …" / "cannot connect …" on failure.
        return text.contains("connected to") || text.contains("already connected")
    }

    @discardableResult
    func disconnect(address: String) async -> Bool {
        guard let result = try? await CommandRunner.run(adbURL, ["disconnect", address]) else { return false }
        return result.exitCode == 0
    }

    /// Restart the adb server to clear a wedged/disabled mDNS daemon. Best-effort.
    func restartServer() async {
        _ = try? await CommandRunner.run(adbURL, ["kill-server"])
        _ = try? await CommandRunner.run(adbURL, ["start-server"])
    }
}
