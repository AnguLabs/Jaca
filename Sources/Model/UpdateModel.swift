import Foundation
import Observation
import AppKit

/// Shared state for the in-app updater. A singleton because both SwiftUI (the
/// sidebar banner) and `JacaAppDelegate` (the AppKit menu-bar) read it. Disabled
/// when no build-info sidecar exists (non-dev build) — the UI then shows nothing.
@Observable
@MainActor
final class UpdateModel {
    static let shared = UpdateModel()

    private(set) var status: UpdateStatus = .unknown
    private(set) var phase: UpdatePhase? = nil
    private(set) var isChecking = false
    let enabled: Bool

    var updateAvailable: Bool {
        if case .available = status { return true }
        return false
    }

    var isUpdating: Bool {
        guard let phase else { return false }
        if case .failed = phase { return false }
        return true
    }

    private let info: BuildInfo?
    private let service = UpdateService()
    private var poll: Task<Void, Never>?

    private init() {
        info = UpdateService.loadBuildInfo()
        enabled = (info != nil)
    }

    /// Checks once now, then re-checks every 30 minutes (git fetch is cheap).
    func start() {
        guard enabled else { return }
        check()
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1800))
                self?.check()
            }
        }
    }

    /// Re-runs detection (skipped while an update is in flight or already checking).
    func check() {
        guard enabled, let info, phase == nil, !isChecking else { return }
        isChecking = true
        let service = service
        Task { [weak self] in
            let result = await service.status(info)
            guard let self else { return }
            self.status = result
            self.isChecking = false
        }
    }

    /// Pulls main, rebuilds, relaunches the new build, and quits this instance.
    func runUpdate() {
        guard enabled, let info, phase == nil else { return }
        let service = service
        Task { [weak self] in
            do {
                let appPath = try await service.performUpdate(info) { ph in
                    Task { @MainActor in self?.phase = ph }
                }
                await Self.relaunch(at: appPath)
            } catch {
                guard let self else { return }
                self.phase = .failed(error.localizedDescription)
                try? await Task.sleep(for: .seconds(8))
                if case .failed = self.phase { self.phase = nil }
                self.check()
            }
        }
    }

    /// Launches the freshly built app and terminates the current instance.
    private static func relaunch(at appPath: String) async {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        _ = try? await NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: appPath), configuration: config
        )
        try? await Task.sleep(for: .milliseconds(700))
        NSApp.terminate(nil)
    }
}
