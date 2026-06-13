import Foundation

/// Whether the installed build is behind `origin/main`.
enum UpdateStatus: Equatable {
    case unknown
    case upToDate
    case available(behind: Int, subject: String)
}

/// The step the update pipeline is currently on (drives the progress UI).
enum UpdatePhase: Equatable, Sendable {
    case stashing
    case switching
    case pulling
    case building
    case launching
    case failed(String)

    var label: String {
        switch self {
        case .stashing: return "Stashing changes…"
        case .switching: return "Switching branch…"
        case .pulling: return "Pulling latest…"
        case .building: return "Building… (this takes a few minutes)"
        case .launching: return "Launching…"
        case .failed(let message): return message
        }
    }
}

/// The repo + commit the running app was built from, read from the build-info
/// sidecar that the build script writes. Absent → not a dev checkout, feature off.
struct BuildInfo: Sendable {
    let repoPath: String
    let buildCommit: String
}

enum UpdateError: Error, LocalizedError {
    case git(String, String)
    case build(String)

    var errorDescription: String? {
        switch self {
        case .git(let cmd, let msg):
            return "git \(cmd) failed: \(msg.isEmpty ? "unknown error" : msg)"
        case .build(let msg):
            return "Build failed: \(msg.isEmpty ? "unknown error" : msg)"
        }
    }
}
