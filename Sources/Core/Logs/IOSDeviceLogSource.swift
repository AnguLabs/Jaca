import Foundation

/// Parses an `idevicesyslog` line into a `LogLine`.
/// Format: `Mon DD HH:MM:SS.ffffff process(Lib)[pid] <Level>: message`
/// (current libimobiledevice emits a sub-second fraction and no hostname; the
/// process name itself can contain spaces, e.g. `Teya Dev(Security)`).
enum IOSSyslogParser {
    // month(1) day(2) time(3) [optional .fraction] process(4) pid(5) level(6) message(7)
    private static let regex = try! NSRegularExpression(
        pattern: #"^(\w{3})\s+(\d+)\s+(\d{2}:\d{2}:\d{2})(?:\.\d+)?\s+(.+?)\[(\d+)\]\s+<(\w+)>:\s?(.*)$"#
    )

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy MMM d HH:mm:ss"
        return f
    }()

    static func parse(_ raw: String, year: Int? = nil) -> LogLine? {
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let m = regex.firstMatch(in: raw, range: range) else { return nil }
        func g(_ i: Int) -> String {
            guard let r = Range(m.range(at: i), in: raw) else { return "" }
            return String(raw[r])
        }
        let y = year ?? Calendar.current.component(.year, from: Date())
        let timestamp = formatter.date(from: "\(y) \(g(1)) \(g(2)) \(g(3))") ?? Date()
        let process = g(4)
        return LogLine(
            seq: 0,
            timestamp: timestamp,
            level: mapLevel(g(6)),
            tag: process,
            pid: Int32(g(5)) ?? 0,
            tid: 0,
            message: g(7),
            raw: raw,
            processName: process
        )
    }

    static func mapLevel(_ level: String) -> LogLevel {
        switch level {
        case "Debug": return .debug
        case "Notice", "Info": return .info
        case "Warning": return .warn
        case "Error": return .error
        case "Fault", "Critical", "Emergency": return .fatal
        default: return .info
        }
    }
}

/// Streams the device syslog from a physically-connected iOS device.
///
/// There is no Android-equivalent pid-scoped per-app stream on iOS hardware; this
/// surfaces the whole device syslog (filter by process in the toolbar). Requires
/// `idevicesyslog` from libimobiledevice (`brew install libimobiledevice`); if
/// it's absent, `start()` throws a clear, actionable error.
final class IOSDeviceLogSource: LogSource {
    private let udid: String
    private var process: StreamingProcess?

    init(udid: String) { self.udid = udid }

    private static func idevicesyslogURL() -> URL? {
        let candidates = ["/opt/homebrew/bin/idevicesyslog", "/usr/local/bin/idevicesyslog"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    func start() throws -> AsyncStream<LogLine> {
        guard let tool = Self.idevicesyslogURL() else {
            throw ProcessError.executableNotFound(
                "idevicesyslog — install with: brew install libimobiledevice"
            )
        }
        let proc = StreamingProcess(executable: tool, arguments: ["-u", udid])
        self.process = proc
        let lineStream = try proc.start()
        return AsyncStream<LogLine> { continuation in
            let task = Task {
                var seq: UInt64 = 0
                for await raw in lineStream {
                    var line = IOSSyslogParser.parse(raw) ?? LogcatParser.fallback(raw)
                    line.seq = seq
                    seq += 1
                    continuation.yield(line)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel(); proc.stop() }
        }
    }

    func stop() { process?.stop() }
}
