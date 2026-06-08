import XCTest
@testable import Jaca

final class AgentTransactionParserTests: XCTestCase {
    func testParsesAgentJSONLine() {
        let line = #"""
        {"type":"txn","id":"7","method":"POST","url":"https://id.teya.xyz/oauth/v2/oauth-token","startedAt":1717800000.5,"responseAt":1717800000.7,"finishedAt":1717800000.9,"status":200,"requestHeaders":{"Content-Type":"application/json"},"responseHeaders":{"Content-Type":"application/json; charset=utf-8"},"requestBody":"{\"a\":1}","responseBody":"{\"ok\":true}","requestSize":7,"responseSize":11,"callStack":["a.A.x(A.java:1)","b.B.y(B.kt:2)"]}
        """#
        let txn = AgentTransactionParser.parse(line)
        XCTAssertNotNil(txn)
        XCTAssertEqual(txn?.method, "POST")
        XCTAssertEqual(txn?.host, "id.teya.xyz")
        XCTAssertEqual(txn?.scheme, "https")
        XCTAssertEqual(txn?.statusCode, 200)
        XCTAssertEqual(txn?.responseContentType, "application/json; charset=utf-8")
        XCTAssertEqual(txn?.callStack?.count, 2)
        XCTAssertEqual(txn?.responseBytes, 11)
    }

    func testIgnoresNonTxnLines() {
        XCTAssertNil(AgentTransactionParser.parse(#"{"type":"hello","pid":1}"#))
        XCTAssertNil(AgentTransactionParser.parse("garbage"))
    }
}

private final class TxnBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [NetworkTransaction] = []
    func add(_ t: NetworkTransaction) { lock.lock(); items.append(t); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    var first: NetworkTransaction? { lock.lock(); defer { lock.unlock() }; return items.first }
}

private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v = "(none)"
    func set(_ s: String) { lock.lock(); v = s; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return v }
}

/// Live end-to-end test of the in-process agent backend (no proxy/CA). Skipped
/// unless an emulator with a debuggable test app and built agent artifacts exist.
final class LiveAgentCaptureTests: XCTestCase {
    func testAgentCapturesLive() async throws {
        let adb = try XCTUnwrap(AndroidToolchain.adbURL(), "adb not found")
        let serial = "emulator-5554"
        let pkg = "com.teya.ac.dev"

        let devices = try? await CommandRunner.run(adb, ["devices"])
        try XCTSkipUnless(devices?.stdout.contains(serial) == true, "no emulator")
        try XCTSkipUnless(AgentArtifacts.isAvailable, "agent artifacts not built (run agent/build*.sh)")
        let debuggable = await AgentController.isDebuggable(adbURL: adb, serial: serial, package: pkg)
        try XCTSkipUnless(debuggable, "test app not present/debuggable")

        // Fresh process so we attach to a stable, known pid (no pid churn).
        let act = "\(pkg)/com.teya.ac.TeyaActivity"
        _ = try? await CommandRunner.run(adb, ["-s", serial, "shell", "am", "force-stop", pkg])
        _ = try? await CommandRunner.run(adb, ["-s", serial, "shell", "am", "start", "-n", act])
        var up = false
        for _ in 0..<10 {
            let p = (try? await CommandRunner.run(adb, ["-s", serial, "shell", "pidof", pkg]))?.stdout ?? ""
            if !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { up = true; break }
            try await Task.sleep(for: .seconds(1))
        }
        try XCTSkipUnless(up, "could not launch \(pkg)")

        let box = TxnBox()
        let statusBox = StatusBox()
        let controller = AgentController(
            adbURL: adb, serial: serial, package: pkg,
            soPath: AgentArtifacts.soURL()!, bootDexPath: AgentArtifacts.bootDexURL!,
            captureDexPath: AgentArtifacts.captureDexURL!,
            onTransaction: { box.add($0) }, onStatus: { statusBox.set($0) }
        )
        controller.start()

        // The pipeline (attach → forward → connect → receive) is proven when the
        // reader gets the agent's hello ("receiving"); a fresh app's startup traffic
        // usually also yields transactions.
        let deadline = Date().addingTimeInterval(25)
        while box.count == 0, !statusBox.value.contains("receiving"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(300))
        }
        controller.stop()

        XCTAssertTrue(statusBox.value.contains("receiving") || box.count > 0,
                      "agent pipeline did not connect (status: \(statusBox.value))")
        if let t = box.first {
            XCTAssertFalse(t.url.isEmpty)
            XCTAssertNotNil(t.callStack, "agent transactions should carry a call stack")
        }
    }

    private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return cond()
    }

    /// The agent must survive the app restarting with a new pid (as a reinstall does):
    /// the supervisor re-attaches automatically and keeps capturing.
    func testAgentReattachesAfterAppRestart() async throws {
        let adb = try XCTUnwrap(AndroidToolchain.adbURL(), "adb not found")
        let serial = "emulator-5554", pkg = "com.teya.ac.dev"
        let devices = try? await CommandRunner.run(adb, ["devices"])
        try XCTSkipUnless(devices?.stdout.contains(serial) == true, "no emulator")
        try XCTSkipUnless(AgentArtifacts.isAvailable, "agent artifacts not built")
        let debuggable = await AgentController.isDebuggable(adbURL: adb, serial: serial, package: pkg)
        try XCTSkipUnless(debuggable, "test app not present/debuggable")

        func launch() async {
            _ = try? await CommandRunner.run(adb, ["-s", serial, "shell", "am", "force-stop", pkg])
            _ = try? await CommandRunner.run(adb, ["-s", serial, "shell", "am", "start", "-n", "\(pkg)/com.teya.ac.TeyaActivity"])
        }
        func pidOf() async -> String {
            ((try? await CommandRunner.run(adb, ["-s", serial, "shell", "pidof", pkg]))?.stdout ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        await launch()
        var pid1 = await pidOf()
        for _ in 0..<10 where pid1.isEmpty { try await Task.sleep(for: .seconds(1)); pid1 = await pidOf() }
        try XCTSkipUnless(!pid1.isEmpty, "could not launch \(pkg)")

        let box = TxnBox()
        let controller = AgentController(
            adbURL: adb, serial: serial, package: pkg,
            soPath: AgentArtifacts.soURL()!, bootDexPath: AgentArtifacts.bootDexURL!,
            captureDexPath: AgentArtifacts.captureDexURL!,
            onTransaction: { box.add($0) }, onStatus: { _ in })
        controller.start()

        let first = await waitUntil(30) { box.count > 0 }
        XCTAssertTrue(first, "no capture from the first process")
        let beforeRestart = box.count

        // Simulate a reinstall: kill + relaunch → new pid.
        await launch()
        var pid2 = await pidOf()
        for _ in 0..<12 where pid2.isEmpty || pid2 == pid1 { try await Task.sleep(for: .seconds(1)); pid2 = await pidOf() }
        XCTAssertNotEqual(pid2, pid1, "expected a new pid after restart")

        let reattached = await waitUntil(45) { box.count > beforeRestart }
        controller.stop()
        XCTAssertTrue(reattached, "agent did not re-attach + capture after the app restarted")
    }
}
