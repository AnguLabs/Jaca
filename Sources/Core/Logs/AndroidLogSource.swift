import Foundation

/// Streams `adb -s <serial> logcat -v threadtime` and parses each line.
/// Filtering by package/text/level is applied downstream (in the session) so a
/// single device stream can feed differently-filtered tabs without re-spawning.
final class AndroidLogSource: LogSource {
    private let adbURL: URL
    private let serial: String
    private let process: StreamingProcess

    init(adbURL: URL, serial: String) {
        self.adbURL = adbURL
        self.serial = serial
        self.process = StreamingProcess(
            executable: adbURL,
            arguments: ["-s", serial, "logcat", "-v", "threadtime"]
        )
    }

    func start() throws -> AsyncStream<LogLine> {
        var stderrLines: [String] = []
        let lineStream = try process.start(onStderrLine: { stderrLines.append($0) })

        return AsyncStream<LogLine> { continuation in
            let task = Task {
                var seq: UInt64 = 0
                for await raw in lineStream {
                    var line = LogcatParser.parse(raw) ?? LogcatParser.fallback(raw)
                    line.seq = seq
                    seq += 1
                    continuation.yield(line)
                }
                continuation.finish()
            }
            continuation.onTermination = { [process] _ in
                task.cancel()
                process.stop()
            }
        }
    }

    func stop() {
        process.stop()
    }

    /// Clears the device-side log buffer (`adb logcat -c`).
    static func clearBuffer(adbURL: URL, serial: String) async {
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "logcat", "-c"])
    }

    /// Resolves the live PID set for a package (`pidof`), used by the package
    /// filter and re-polled so it survives app restarts (PID changes).
    static func resolvePIDs(adbURL: URL, serial: String, package: String) async -> Set<Int32> {
        guard !package.isEmpty,
              let result = try? await CommandRunner.run(
                  adbURL, ["-s", serial, "shell", "pidof", package]
              ), result.exitCode == 0 else { return [] }
        let pids = result.stdout
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .compactMap { Int32($0) }
        return Set(pids)
    }
}
