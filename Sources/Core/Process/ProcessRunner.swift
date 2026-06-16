import Foundation

/// Errors surfaced when launching or running external tools (adb, xcrun, …).
enum ProcessError: Error, LocalizedError {
    case executableNotFound(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path): return "Executable not found: \(path)"
        case .launchFailed(let reason): return "Failed to launch process: \(reason)"
        }
    }
}

/// One-shot command execution: run to completion and collect output.
/// Used for short queries like `adb devices -l`, `getprop`, `pidof`.
enum CommandRunner {
    struct Result: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs `executable args…` to completion off the calling actor.
    /// Throws `ProcessError` only on launch failure; a non-zero exit is returned
    /// in `Result.exitCode` (callers decide whether that's fatal).
    static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProcessError.executableNotFound(executable.path)
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let environment { process.environment = environment }
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProcessError.launchFailed(error.localizedDescription))
                    return
                }
                // Read fully before waitUntilExit to avoid deadlock on large output.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Result(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}

/// A long-running child process whose stdout is exposed as a line `AsyncStream`.
/// Used to stream `adb logcat`. stderr lines are delivered via `onStderrLine`
/// (adb prints "waiting for device", auth errors, etc. there). The stream
/// finishes when the process exits or `stop()` is called.
final class StreamingProcess: @unchecked Sendable {
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]?
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private let lock = NSLock()
    private var continuation: AsyncStream<String>.Continuation?

    init(executable: URL, arguments: [String], environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    /// Launches the process and returns the stdout line stream.
    /// Throws `ProcessError` if the executable is missing or fails to launch.
    func start(onStderrLine: (@Sendable (String) -> Void)? = nil) throws -> AsyncStream<String> {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProcessError.executableNotFound(executable.path)
        }

        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stream = AsyncStream<String>(bufferingPolicy: .unbounded) { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty { return }
            self.consumeStdout(data)
        }

        if let onStderrLine {
            stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let data = handle.availableData
                if data.isEmpty { return }
                self.consumeStderr(data, sink: onStderrLine)
            }
        }

        process.terminationHandler = { [weak self] _ in
            self?.finish()
        }

        do {
            try process.run()
        } catch {
            finish()
            throw ProcessError.launchFailed(error.localizedDescription)
        }
        return stream
    }

    /// Terminates the process and finishes the stream. Idempotent.
    /// SIGTERM, then SIGKILL after a short grace period: some tools (notably
    /// `idevicesyslog`) can ignore SIGTERM, and a survivor keeps holding the
    /// device's single syslog-relay connection — starving every later stream
    /// until it's killed. The escalation is a no-op for tools that exit cleanly.
    func stop() {
        let p = process
        if p.isRunning {
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
        }
        finish()
    }

    private func consumeStdout(_ data: Data) {
        lock.lock()
        stdoutBuffer.append(data)
        let lines = Self.drainLines(from: &stdoutBuffer)
        let cont = continuation
        lock.unlock()
        for line in lines { cont?.yield(line) }
    }

    private func consumeStderr(_ data: Data, sink: @Sendable (String) -> Void) {
        lock.lock()
        stderrBuffer.append(data)
        let lines = Self.drainLines(from: &stderrBuffer)
        lock.unlock()
        for line in lines where !line.isEmpty { sink(line) }
    }

    private func finish() {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        guard cont != nil else { return }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        cont?.finish()
    }

    /// Splits complete `\n`-terminated lines out of `buffer`, leaving any partial
    /// trailing line in place for the next chunk.
    private static func drainLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        let newline = UInt8(ascii: "\n")
        while let idx = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<idx]
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...idx)
        }
        return lines
    }
}
