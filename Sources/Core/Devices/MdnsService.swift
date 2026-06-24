import Foundation

/// The three mDNS service types adb advertises/browses. We key pairing and
/// auto-reconnect off these. See `aosp-adb/adb_mdns.{h,cpp}`:
///   _adb-tls-pairing._tcp  — a device sitting on its "Wireless debugging → Pair"
///                            screen (advertised only while that screen is open).
///   _adb-tls-connect._tcp  — an already-paired device ready to be connected to.
///   _adb._tcp              — legacy plaintext (`adb tcpip`), port 5555.
enum AdbMdnsServiceType: String, Sendable, CaseIterable {
    case pairing = "_adb-tls-pairing._tcp"
    case connect = "_adb-tls-connect._tcp"
    case legacy  = "_adb._tcp"
}

/// One line of `adb mdns services` output: an instance name, a service type, and
/// the host:port the service is reachable at. The instance name doubles as the
/// device GUID for `_adb-tls-connect` (e.g. "adb-939AX05XBZ-vWgJpq") and as our
/// chosen QR service name for `_adb-tls-pairing` after a QR scan.
struct MdnsService: Identifiable, Hashable, Sendable {
    let instance: String
    /// Raw service type, normalized without a trailing dot (e.g. "_adb-tls-pairing._tcp").
    let serviceType: String
    let ip: String
    let port: Int

    var address: String { "\(ip):\(port)" }
    var kind: AdbMdnsServiceType? { AdbMdnsServiceType(rawValue: serviceType) }
    /// Stable identity: same service can be heard under multiple types, so include all.
    var id: String { "\(instance)\t\(serviceType)\t\(address)" }
}

/// Parses `adb mdns services` text output into `MdnsService`s. Pure & synchronous
/// for testing, mirroring `AndroidDeviceParser`. Each useful line is tab-separated:
///
///     List of discovered mdns services
///     adb-939AX05XBZ-vWgJpq	_adb-tls-connect._tcp	192.168.1.86:39149
///     adb-939AX05XBZ-vWgJpq	_adb-tls-pairing._tcp	192.168.1.86:37313
///
/// Some adb builds use spaces instead of tabs, so we fall back to whitespace splitting.
/// Mirrors adblib's `MdnsServiceListParser`: drops `0.0.0.0` rows (b/390429989) and
/// deduplicates identical entries.
enum MdnsServiceParser {
    static func parse(_ output: String) -> [MdnsService] {
        var services: [MdnsService] = []
        var seen = Set<String>()

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("List of") { continue }     // header
            if line.hasPrefix("*") { continue }           // "* daemon started …"
            if line.hasPrefix("adb:") { continue }        // error lines

            // Prefer tab separation (the documented format); fall back to runs of
            // whitespace for adb builds that align columns with spaces.
            let fields: [String]
            if line.contains("\t") {
                fields = line.split(separator: "\t", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                fields = line.split(whereSeparator: { $0 == " " })
                    .map(String.init)
            }
            guard fields.count >= 3 else { continue }

            let instance = fields[0]
            let serviceType = normalizeType(fields[1])
            // The address is the last field; everything between is part of the type
            // only in malformed lines, so take first three meaningful columns.
            guard let (ip, port) = splitAddress(fields[2]) else { continue }
            if ip == "0.0.0.0" { continue }               // bogus row adb sometimes emits

            let service = MdnsService(instance: instance, serviceType: serviceType, ip: ip, port: port)
            if seen.insert(service.id).inserted {
                services.append(service)
            }
        }
        return services
    }

    /// Strips a trailing `.` adb appends in some builds ("_adb-tls-connect._tcp.").
    private static func normalizeType(_ raw: String) -> String {
        raw.hasSuffix(".") ? String(raw.dropLast()) : raw
    }

    /// Splits "192.168.1.86:39149" into ("192.168.1.86", 39149). Tolerates IPv6 by
    /// splitting on the final colon.
    private static func splitAddress(_ raw: String) -> (ip: String, port: Int)? {
        guard let colon = raw.lastIndex(of: ":") else { return nil }
        let ip = String(raw[raw.startIndex..<colon])
        let portStr = String(raw[raw.index(after: colon)...])
        guard !ip.isEmpty, let port = Int(portStr), port > 0 else { return nil }
        return (ip, port)
    }
}
