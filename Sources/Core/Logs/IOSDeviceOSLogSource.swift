import Foundation

/// Physical-device **structured** logs (level · subsystem · category · message) via
/// Apple's private `LoggingSupport` engine, bridged through `JacaOSLogStream`. This is
/// the Xcode/Console-grade stream `idevicesyslog` and `devicectl --console` can't give:
/// passive (no app launch, no relaunch, no device-unlock), with real levels.
///
/// Whole-device by nature; `processFilter` (the app's process/display name) narrows it
/// to one app. If the private API can't load on this macOS/Xcode build, it falls back
/// to `idevicesyslog` and surfaces a clear marker — never hard-fails. If the framework
/// internals shift, see the `investigate-loggingsupport` skill.
final class IOSDeviceOSLogSource: LogSource {
    private let udid: String
    private let processFilter: String?
    private let lock = NSLock()
    private var continuation: AsyncStream<LogLine>.Continuation?
    private var stream: JacaOSLogStream?
    private var fallback: IOSDeviceLogSource?
    private var fallbackTask: Task<Void, Never>?

    init(udid: String, processFilter: String?) {
        self.udid = udid
        self.processFilter = (processFilter?.isEmpty == true) ? nil : processFilter
    }

    func start() throws -> AsyncStream<LogLine> {
        var cont: AsyncStream<LogLine>.Continuation!
        let out = AsyncStream<LogLine>(bufferingPolicy: .unbounded) { cont = $0 }
        lock.lock(); continuation = cont; lock.unlock()

        if let s = JacaOSLogStream(udid: udid, onEvent: { [weak self] ev in self?.emit(ev) }), s.start() {
            stream = s
            let scope = processFilter.map { "“\($0)”" } ?? "whole device"
            yieldMarker("▶︎ structured device logs via LoggingSupport (\(scope)) — level · subsystem · category")
        } else {
            // Private API unavailable (newer macOS/Xcode, or device handle missing) → fall back.
            yieldMarker("⚠️ Apple LoggingSupport unavailable on this build — falling back to syslog (flat, redacted, no print/levels-only-notice)")
            let fb = IOSDeviceLogSource(udid: udid)
            fallback = fb
            if let fs = try? fb.start() {
                fallbackTask = Task { [weak self] in
                    for await line in fs { self?.yield(line) }
                    self?.finish()
                }
            } else {
                cont.finish()
            }
        }
        cont.onTermination = { [weak self] _ in self?.stop() }
        return out
    }

    func stop() {
        stream?.stop(); stream = nil
        fallbackTask?.cancel(); fallbackTask = nil
        fallback?.stop(); fallback = nil
        finish()
    }

    // MARK: - emit

    private func emit(_ ev: JacaOSLogEvent) {
        // Client-side narrowing to the targeted app (whole-device stream otherwise).
        if let pf = processFilter {
            let p = ev.process ?? ""
            if p.range(of: pf, options: .caseInsensitive) == nil { return }
        }
        // Tag = subsystem (preferred), matching SimulatorLogSource — so Jaca's
        // "hide system logs" filter can drop the com.apple.* framework noise that
        // Network/CFNetwork/CoreFoundation emit *inside* the app's own process.
        let tag = (ev.subsystem?.isEmpty == false ? ev.subsystem : ev.category) ?? (ev.process ?? "")
        let message = ev.message ?? ""
        let line = LogLine(
            seq: 0,
            timestamp: ev.timestamp > 0 ? Date(timeIntervalSince1970: ev.timestamp) : Date(),
            level: Self.mapLevel(ev.level),
            tag: tag,
            pid: Int32(ev.processID),
            tid: 0,
            message: message,
            raw: message,
            processName: ev.process
        )
        yield(line)
    }

    /// `OSActivityLogMessageEvent.messageType` → Jaca level.
    /// 0=Default, 1=Info, 2=Debug, 16=Error, 17=Fault. (os_log has no warn level.)
    static func mapLevel(_ t: UInt8) -> LogLevel {
        switch t {
        case 0x02: return .debug
        case 0x10: return .error
        case 0x11: return .fatal
        default:   return .info   // Default + Info
        }
    }

    private func yield(_ line: LogLine) {
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(line)
    }
    private func yieldMarker(_ message: String) { yield(LogLine.marker(message)) }
    private func finish() {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.finish()
    }
}
