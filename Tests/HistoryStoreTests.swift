import XCTest
@testable import Squeeze

final class HistoryStoreTests: XCTestCase {
    private func makeStore() throws -> (HistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("squeeze-test-\(UUID().uuidString).sqlite")
        let store = try XCTUnwrap(HistoryStore(url: url))
        return (store, url)
    }

    private func line(_ seq: UInt64, _ level: LogLevel, _ msg: String) -> LogLine {
        LogLine(seq: seq, timestamp: Date(), level: level, tag: "T",
                pid: 1, tid: 1, message: msg, raw: "", processName: "proc")
    }

    func testPersistAndQueryAcrossSessions() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let device = Device(id: "emulator-5554", platform: .android, model: "Pixel", state: .connected)
        await store.upsertDevice(device)

        let s1 = UUID(), s2 = UUID()
        await store.beginSession(id: s1, device: device, package: "com.foo", displayName: "Run 1")
        await store.appendLines(sessionID: s1, [line(0, .info, "alpha"), line(1, .error, "beta")])
        await store.beginSession(id: s2, device: device, package: "com.foo", displayName: "Run 2")
        await store.appendLines(sessionID: s2, [line(0, .warn, "gamma")])

        // Both sessions show up for the same device + package.
        let sessions = await store.sessions(deviceID: "emulator-5554", package: "com.foo")
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.displayName)), ["Run 1", "Run 2"])
        XCTAssertEqual(sessions.first(where: { $0.id == s1.uuidString })?.lineCount, 2)

        // Package groups aggregate.
        let groups = await store.packageGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.package, "com.foo")
        XCTAssertEqual(groups.first?.sessions, 2)
    }

    func testLineRetrievalAndSearch() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let device = Device(id: "d1", platform: .android, model: "M", state: .connected)
        let sid = UUID()
        await store.beginSession(id: sid, device: device, package: "p", displayName: "S")
        await store.appendLines(sessionID: sid, [
            line(0, .info, "loading user profile"),
            line(1, .debug, "network request started"),
            line(2, .info, "user profile loaded"),
        ])

        let all = await store.lines(sessionID: sid)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map(\.seq), [0, 1, 2])  // ordered by seq

        let hits = await store.lines(sessionID: sid, search: "profile")
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits.allSatisfy { $0.message.contains("profile") })
    }

    func testPruneRemovesOldSessions() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let device = Device(id: "d1", platform: .android, model: "M", state: .connected)
        let old = UUID(), recent = UUID()
        let longAgo = Date().addingTimeInterval(-100_000)
        await store.beginSession(id: old, device: device, package: "p", displayName: "old", startedAt: longAgo)
        await store.appendLines(sessionID: old, [line(0, .info, "old line")])
        await store.beginSession(id: recent, device: device, package: "p", displayName: "new")
        await store.appendLines(sessionID: recent, [line(0, .info, "new line")])

        await store.prune(olderThan: Date().addingTimeInterval(-50_000))

        let sessions = await store.sessions(deviceID: "d1")
        XCTAssertEqual(sessions.map(\.displayName), ["new"])
        let oldLines = await store.lines(sessionID: old)
        let recentLines = await store.lines(sessionID: recent)
        XCTAssertTrue(oldLines.isEmpty)
        XCTAssertEqual(recentLines.count, 1)
    }
}
