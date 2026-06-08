import XCTest
@testable import Jaca

/// End-to-end MITM proxy check: route a real HTTPS request through the proxy with
/// the generated root CA trusted, and confirm TLS is terminated, the upstream is
/// reached, and a transaction is captured. Skipped if the network is unavailable.
final class ProxyServerTests: XCTestCase {
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var transactions: [NetworkTransaction] = []
        func add(_ t: NetworkTransaction) { lock.lock(); transactions.append(t); lock.unlock() }
    }

    func testInterceptsHTTPSThroughProxy() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("squeeze-ca-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ca = try CertificateAuthority(directory: dir)

        let sink = Sink()
        let proxy = ProxyServer(port: 0, ca: ca) { sink.add($0) }
        try proxy.start()
        defer { proxy.stop() }
        let port = proxy.boundPort
        XCTAssertGreaterThan(port, 0)

        let caPath = dir.appendingPathComponent("rootCA.pem").path

        // curl through the proxy, trusting our root CA.
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = [
            "-s", "-o", "/dev/null", "-w", "%{http_code}",
            "--max-time", "20",
            "-x", "http://127.0.0.1:\(port)",
            "--cacert", caPath,
            "https://example.com/",
        ]
        let out = Pipe()
        curl.standardOutput = out
        try curl.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        curl.waitUntilExit()
        let code = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespaces)

        try XCTSkipIf(code == "000" || code.isEmpty, "network unavailable (curl returned \(code))")
        XCTAssertEqual(code, "200", "request through proxy should succeed with trusted CA")

        // Allow the async transaction emit to land.
        let deadline = Date().addingTimeInterval(3)
        while sink.transactions.filter({ !$0.isInFlight }).isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let completed = sink.transactions.filter { !$0.isInFlight }
        XCTAssertFalse(completed.isEmpty, "expected a captured transaction")
        let example = completed.first { $0.host.contains("example.com") }
        XCTAssertNotNil(example, "should capture the example.com request")
        XCTAssertEqual(example?.statusCode, 200)
        XCTAssertEqual(example?.scheme, "https")
    }
}
