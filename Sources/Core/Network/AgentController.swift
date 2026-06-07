import Foundation

/// Parses one agent JSON line into a NetworkTransaction. Pure & testable.
enum AgentTransactionParser {
    static func parse(_ line: String) -> NetworkTransaction? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "txn" else { return nil }

        let url = obj["url"] as? String ?? ""
        let comps = URLComponents(string: url)
        var txn = NetworkTransaction(
            method: obj["method"] as? String ?? "GET",
            url: url,
            host: comps?.host ?? "",
            scheme: comps?.scheme ?? (url.hasPrefix("https") ? "https" : "http"),
            requestHeaders: headers(obj["requestHeaders"]),
            requestBody: bodyData(obj["requestBody"]),
            startedAt: date(obj["startedAt"]) ?? Date()
        )
        if let status = obj["status"] as? Int, status > 0 { txn.statusCode = status }
        txn.responseHeaders = headers(obj["responseHeaders"])
        txn.responseBody = bodyData(obj["responseBody"])
        txn.responseContentType = txn.responseHeaders.first { $0.name.lowercased() == "content-type" }?.value
        txn.responseReceivedAt = date(obj["responseAt"])
        txn.finishedAt = date(obj["finishedAt"])
        txn.requestBytes = obj["requestSize"] as? Int ?? (txn.requestBody?.count ?? 0)
        txn.responseBytes = obj["responseSize"] as? Int ?? (txn.responseBody?.count ?? 0)
        txn.error = obj["error"] as? String
        txn.callStack = (obj["callStack"] as? [Any])?.compactMap { $0 as? String }
        return txn
    }

    private static func headers(_ any: Any?) -> [HeaderPair] {
        guard let dict = any as? [String: Any] else { return [] }
        return dict.map { HeaderPair(name: $0.key, value: "\($0.value)") }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
    private static func bodyData(_ any: Any?) -> Data? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        return s.data(using: .utf8)
    }
    private static func date(_ any: Any?) -> Date? {
        guard let t = any as? Double, t > 0 else { return nil }
        return Date(timeIntervalSince1970: t)
    }
}

/// Drives the in-process agent for a debuggable Android app: push artifacts,
/// attach via `cmd activity attach-agent` (no root), `adb forward` the agent's
/// localabstract socket, and stream captured transactions to `onTransaction`.
final class AgentController: @unchecked Sendable {
    private let adbURL: URL
    private let serial: String
    private let package: String
    private let soPath: URL
    private let bootDexPath: URL
    private let captureDexPath: URL
    private let socketName: String
    private let onTransaction: @Sendable (NetworkTransaction) -> Void
    private let onStatus: @Sendable (String) -> Void

    private var forwardedPort: Int32 = 0
    private var fd: Int32 = -1
    private var readerThread: Thread?
    private var stopped = false

    init(adbURL: URL, serial: String, package: String, soPath: URL,
         bootDexPath: URL, captureDexPath: URL,
         onTransaction: @escaping @Sendable (NetworkTransaction) -> Void,
         onStatus: @escaping @Sendable (String) -> Void) {
        self.adbURL = adbURL
        self.serial = serial
        self.package = package
        self.soPath = soPath
        self.bootDexPath = bootDexPath
        self.captureDexPath = captureDexPath
        self.socketName = "squeeze_\(UInt32.random(in: 1...0xFFFFFF))"
        self.onTransaction = onTransaction
        self.onStatus = onStatus
    }

    /// Checks whether `package` is debuggable (run-as succeeds only for debug builds).
    static func isDebuggable(adbURL: URL, serial: String, package: String) async -> Bool {
        let r = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "run-as", package, "true"])
        return r?.exitCode == 0
    }

    func start() {
        Task { await setup() }
    }

    private func adb(_ args: [String]) async -> CommandRunner.Result? {
        try? await CommandRunner.run(adbURL, ["-s", serial] + args)
    }

    private func setup() async {
        let cc = "/data/data/\(package)/code_cache"
        let tmp = "/data/local/tmp/squeeze"

        guard let pidOut = await adb(["shell", "pidof", package]) else {
            onStatus("agent: app not running"); return
        }
        // pidof returns "1234 5678\n" — take the first, fully trimmed (a stray
        // newline here would corrupt the attach-agent command).
        let pid = pidOut.stdout
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" })
            .first.map(String.init) ?? ""
        guard !pid.isEmpty else { onStatus("agent: app not running"); return }

        _ = await adb(["shell", "mkdir", "-p", tmp])
        _ = await adb(["push", soPath.path, "\(tmp)/libsqueezeagent.so"])
        _ = await adb(["push", bootDexPath.path, "\(tmp)/squeezeagent-boot.dex"])
        _ = await adb(["push", captureDexPath.path, "\(tmp)/squeezeagent-capture.dex"])
        // Copy into the app's code_cache (SELinux: app can exec from there) via run-as.
        _ = await adb(["shell", "run-as", package, "rm", "-rf",
                       "code_cache/libsqueezeagent.so", "code_cache/squeezeagent-boot.dex",
                       "code_cache/squeezeagent-capture.dex", "code_cache/squeeze_opt"])
        for file in ["libsqueezeagent.so", "squeezeagent-boot.dex", "squeezeagent-capture.dex"] {
            _ = await adb(["shell", "run-as \(package) sh -c 'cat > \(cc)/\(file)' < \(tmp)/\(file)"])
        }
        _ = await adb(["shell", "run-as", package, "chmod", "444",
                       "code_cache/squeezeagent-boot.dex", "code_cache/squeezeagent-capture.dex"])  // ART rejects writable dex

        let spec = "\(cc)/libsqueezeagent.so=\(cc)/squeezeagent-boot.dex,\(cc)/squeezeagent-capture.dex,\(socketName)"
        _ = await adb(["shell", "cmd activity attach-agent \(pid) '\(spec)'"])

        guard let fwd = await adb(["forward", "tcp:0", "localabstract:\(socketName)"]),
              let port = Int32(fwd.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            onStatus("agent: adb forward failed"); return
        }
        forwardedPort = port
        onStatus("agent: in-process (debuggable)")
        startReader(port: port)
    }

    private func startReader(port: Int32) {
        let thread = Thread { [weak self] in self?.readLoop(port: port) }
        thread.name = "squeeze-agent-reader"
        readerThread = thread
        thread.start()
    }

    private func readLoop(port: Int32) {
        // `connect()` to adb's forward always succeeds, but adb closes the stream if
        // the device-side localabstract server isn't accepting yet (a race right
        // after attach). So retry the whole connect+read until we actually receive
        // bytes (the agent's hello), then stream for real.
        var attempts = 0
        while !stopped && attempts < 40 {
            attempts += 1
            let s = connect(port: port)
            if s < 0 { Thread.sleep(forTimeInterval: 0.25); continue }
            fd = s
            onStatus("agent: connected :\(port)")
            let receivedAny = streamFrom(fd: s)
            if fd >= 0 { close(fd); fd = -1 }
            if receivedAny || stopped { return }
            Thread.sleep(forTimeInterval: 0.25)  // closed before any data — retry
        }
        onStatus("agent: could not connect to socket :\(port)")
    }

    /// Reads newline-delimited JSON from `s`. Returns true if any bytes arrived.
    private func streamFrom(fd s: Int32) -> Bool {
        var firstData = true
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        while !stopped {
            let n = recv(s, &chunk, chunk.count, 0)
            if n <= 0 { break }
            if firstData { firstData = false; onStatus("agent: in-process (receiving)") }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8),
                   let txn = AgentTransactionParser.parse(line) {
                    onTransaction(txn)
                }
            }
        }
        return !firstData
    }

    private func connect(port: Int32) -> Int32 {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return -1 }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r != 0 { close(s); return -1 }
        return s
    }

    func stop() {
        stopped = true
        if fd >= 0 { close(fd); fd = -1 }
        let p = forwardedPort
        if p > 0 {
            let url = adbURL, serial = serial
            Task { _ = try? await CommandRunner.run(url, ["-s", serial, "forward", "--remove", "tcp:\(p)"]) }
        }
    }
}
