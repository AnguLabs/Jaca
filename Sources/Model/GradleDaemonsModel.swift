import Foundation
import Observation

/// A transient toast shown over the Gradle area (mirrors `WorktreesToast`).
struct GradleToast: Equatable { var message: String; var systemFallback: String }

/// State for the Gradle top-level area: the live list of Gradle daemons, polled
/// every couple of seconds, with kill actions. Mirrors `WorktreesModel`'s toast +
/// polling idioms.
@Observable
@MainActor
final class GradleDaemonsModel {
    var daemons: [GradleDaemon] = []
    var toast: GradleToast? = nil

    private let service = GradleDaemonService()
    private var timer: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    // MARK: - Toast

    func flash(_ message: String, fallback: String = "checkmark") {
        toastTask?.cancel()
        toast = GradleToast(message: message, systemFallback: fallback)
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2600))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: - Refresh

    func refresh() {
        let service = self.service
        Task { [weak self] in
            let list = await service.list()
            guard let self else { return }
            // Preserve the in-flight removing flag so a row mid-fade doesn't reappear.
            let removing = Set(self.daemons.filter(\.removing).map(\.pid))
            self.daemons = list.map { d in
                guard removing.contains(d.pid) else { return d }
                var copy = d
                copy.removing = true
                return copy
            }
        }
    }

    // MARK: - Kill

    func kill(_ pid: Int32) {
        guard let i = daemons.firstIndex(where: { $0.pid == pid }) else { return }
        daemons[i].removing = true
        let service = self.service
        Task { [weak self] in
            let ok = await service.kill(pid: pid)
            guard let self else { return }
            if ok {
                try? await Task.sleep(for: .milliseconds(280))
                self.daemons.removeAll { $0.pid == pid }
                self.flash("Killed \(pid)", fallback: "eraser")
            } else {
                if let j = self.daemons.firstIndex(where: { $0.pid == pid }) {
                    self.daemons[j].removing = false
                }
                self.flash("Couldn't kill \(pid)", fallback: "eraser")
            }
        }
    }

    // MARK: - Polling

    func startPolling() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopPolling() {
        timer?.cancel()
        timer = nil
    }
}
