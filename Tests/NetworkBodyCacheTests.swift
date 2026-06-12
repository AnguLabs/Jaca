import XCTest
@testable import Jaca

final class NetworkBodyCacheTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval, _ cond: @MainActor () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await MainActor.run(body: cond) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await MainActor.run(body: cond)
    }

    func testBodyCacheRoundTrips() async throws {
        let cache = try XCTUnwrap(NetworkBodyCache())
        let id = UUID()
        let req = Data("the-request".utf8), resp = Data(repeating: 7, count: 4096)
        await cache.save(id, req: req, resp: resp)
        let loaded = await cache.load(id)
        XCTAssertEqual(loaded.req, req)
        XCTAssertEqual(loaded.resp, resp)

        let missing = await cache.load(UUID())
        XCTAssertNil(missing.req); XCTAssertNil(missing.resp)
    }

    @MainActor
    func testOlderBodiesEvictToDiskAndReloadOnSelect() async throws {
        let ca = try XCTUnwrap(try? CertificateAuthority())
        let cache = try XCTUnwrap(NetworkBodyCache())
        let device = Device(id: "dev", platform: .android, model: "Model", state: .connected)
        let session = NetworkSession(device: device, ca: ca, adbURL: nil, bodyCache: cache)

        var firstID = UUID()
        for i in 0..<1_002 {   // exceed the in-memory body window (1000) by a couple
            var t = NetworkTransaction(method: "GET", url: "https://x/\(i)", host: "x", scheme: "https")
            t.requestBody = Data("body-\(i)".utf8)
            t.requestBytes = t.requestBody!.count
            if i == 0 { firstID = t.id }
            session.upsert(t)
        }

        // Nothing dropped — every transaction's metadata is retained.
        XCTAssertEqual(session.transactions.count, 1_002)

        // The oldest spilled its body to disk and cleared it from memory.
        let evicted = await waitUntil(3) {
            session.transactions.first?.bodiesEvicted == true && session.transactions.first?.requestBody == nil
        }
        XCTAssertTrue(evicted, "oldest body should be evicted to disk")

        // Selecting it reloads the body from disk.
        session.selectedID = firstID
        let reloaded = await waitUntil(3) { session.transactions.first?.requestBody != nil }
        XCTAssertTrue(reloaded, "selecting an evicted transaction should reload its body")
        XCTAssertEqual(session.transactions.first?.requestBody, Data("body-0".utf8))
    }
}
