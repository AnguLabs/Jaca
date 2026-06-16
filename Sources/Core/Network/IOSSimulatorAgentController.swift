import Foundation

/// Drives in-process network capture for a debug app on the iOS **Simulator** — no
/// proxy, no CA cert. It binds a localhost TCP listener, launches the app via
/// `simctl launch` with `DYLD_INSERT_LIBRARIES` pointing at the bundled `JacaNetAgent`
/// dylib (and the listener port), and streams the agent's newline-delimited JSON into
/// the shared `AgentTransactionParser` — the same wire format as the Android agent.
///
/// The simulator shares the Mac's loopback, so the injected agent simply connects back
/// to `127.0.0.1:<port>`. If the app relaunches, its fresh agent reconnects and the
/// accept loop picks it up again.
final class IOSSimulatorAgentController: @unchecked Sendable {
    private let udid: String
    private let bundleID: String
    private let agentDylib: URL
    private let onTransaction: @Sendable (NetworkTransaction) -> Void
    private let onStatus: @Sendable (String) -> Void

    private var listenFD: Int32 = -1
    private var connFD: Int32 = -1
    private var port: UInt16 = 0
    private var acceptThread: Thread?
    private var stopped = false

    init(udid: String, bundleID: String, agentDylib: URL,
         onTransaction: @escaping @Sendable (NetworkTransaction) -> Void,
         onStatus: @escaping @Sendable (String) -> Void) {
        self.udid = udid
        self.bundleID = bundleID
        self.agentDylib = agentDylib
        self.onTransaction = onTransaction
        self.onStatus = onStatus
    }

    func start() {
        stopped = false
        guard bindListener() else { onStatus("network agent: couldn't open local listener"); return }
        startAcceptLoop()
        Task { await launch() }
    }

    func stop() {
        stopped = true
        if connFD >= 0 { close(connFD); connFD = -1 }
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }

    // MARK: - listener

    /// Binds 127.0.0.1:0 (OS-assigned port) and starts listening; records the port.
    private func bindListener() -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(s, 4) == 0 else { close(s); return false }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(s, $0, &len) }
        }
        port = UInt16(bigEndian: addr.sin_port)
        listenFD = s
        return true
    }

    private func launch() async {
        var env = AppleToolchain.environment()
        // simctl passes SIMCTL_CHILD_-prefixed vars into the launched app's environment.
        env["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = agentDylib.path
        env["SIMCTL_CHILD_JACA_NET_PORT"] = String(port)
        onStatus("network agent: launching \(bundleID)…")
        let r = try? await CommandRunner.run(
            AppleToolchain.xcrun,
            ["simctl", "launch", "--terminate-running-process", udid, bundleID],
            environment: env
        )
        if r?.exitCode == 0 {
            onStatus("network agent: in-process (\(bundleID))")
        } else {
            onStatus("network agent: couldn't launch \(bundleID)")
        }
    }

    // MARK: - reader

    private func startAcceptLoop() {
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "jaca-net-agent"
        acceptThread = t
        t.start()
    }

    /// Accepts the agent's connection and streams its frames; if the app relaunches
    /// (re-injected agent → new connection), loops back and accepts again.
    private func acceptLoop() {
        while !stopped {
            let c = accept(listenFD, nil, nil)
            if c < 0 { if stopped { return }; Thread.sleep(forTimeInterval: 0.2); continue }
            connFD = c
            onStatus("network agent: connected")
            streamFrom(fd: c)
            close(c); connFD = -1
            if stopped { return }
        }
    }

    /// Reads newline-delimited JSON, parsing each line via the shared agent parser.
    private func streamFrom(fd s: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        while !stopped {
            let n = recv(s, &chunk, chunk.count, 0)
            if n <= 0 { break }
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
    }
}
