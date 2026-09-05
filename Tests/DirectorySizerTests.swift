import XCTest
@testable import Jaca

final class DirectorySizerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DirectorySizerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ rel: String, bytes: Int) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(count: bytes).write(to: url)
    }

    func test_size_sumsEveryFileAndAttributesCacheDirs() async throws {
        try write("a.txt", bytes: 1000)
        try write("src/deep/c.txt", bytes: 2000)
        try write("node_modules/pkg/b.bin", bytes: 4000)

        let (total, cache) = await DirectorySizer(cacheDirs: ["node_modules"]).size(root)

        XCTAssertEqual(total, 7000)
        XCTAssertEqual(cache, 4000)
    }

    func test_size_ignoresSymlinks() async throws {
        try write("a.txt", bytes: 1000)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"),
            withDestinationURL: root.appendingPathComponent("a.txt")
        )

        let (total, _) = await DirectorySizer(cacheDirs: []).size(root)

        XCTAssertEqual(total, 1000)
    }

    func test_size_countsAHardlinkedFileOnce() async throws {
        try write("a.txt", bytes: 1000)
        try FileManager.default.linkItem(
            at: root.appendingPathComponent("a.txt"),
            to: root.appendingPathComponent("copy.txt")
        )

        let (total, _) = await DirectorySizer(cacheDirs: []).size(root)

        XCTAssertEqual(total, 1000)
    }

    func test_size_matchesCacheDirsByRelativePathOnly() async throws {
        try write("build/out.bin", bytes: 500)
        try write("src/build/out.bin", bytes: 700)

        let (total, cache) = await DirectorySizer(cacheDirs: ["build"]).size(root)

        XCTAssertEqual(total, 1200)
        XCTAssertEqual(cache, 500)
    }

    func test_size_stopsWhenTheTaskIsCancelled() async throws {
        for i in 0..<200 { try write("d\(i)/f.bin", bytes: 1000) }

        let task = Task { await DirectorySizer(cacheDirs: []).size(root) }
        task.cancel()
        let (total, _) = await task.value

        XCTAssertLessThanOrEqual(total, 200_000)
    }
}
