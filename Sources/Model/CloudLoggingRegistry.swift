import Foundation
import Observation

/// Transient feedback for the Cloud Logging area (mirrors `ProjectsToast`).
struct CloudLoggingToast: Equatable { var message: String; var systemFallback: String }

/// gcloud detection + sign-in status.
enum CloudAuthState: Equatable, Sendable {
    case unknown            // not checked yet
    case notInstalled       // no gcloud binary found
    case notAuthenticated   // gcloud present but no active account
    case authenticated(account: String)
}

/// THE single source of truth for Cloud Logging (per the single-source-of-truth convention,
/// mirrors `CompanionRegistry`). One observable owner of: gcloud detection + auth state, the
/// persisted project list, and the **global per-project** state — the selected log name, the
/// cached available log names, and the auto-detected label keys. Every `CloudLogSession` reads
/// this reactively, so changing the log name (or a detected label key appearing) in one tab is
/// reflected in every tab for that project, with no per-view polling (req 7).
@Observable @MainActor
final class CloudLoggingRegistry {
    // MARK: Detection / auth

    private(set) var binaryURL: URL?
    private(set) var isDetecting = false
    private(set) var authState: CloudAuthState = .unknown

    /// True once a `gcloud` binary has been located — gates whether the Cloud Logging UI shows.
    var isAvailable: Bool { binaryURL != nil }
    var cli: GcloudCLI? { binaryURL.map { GcloudCLI(binary: $0) } }
    /// The exact command we tell the user to run in a terminal to sign in (req 2).
    let authCommand = "gcloud auth login"

    // MARK: Projects (single source of truth, persisted to ~/.jaca)

    private(set) var projects: [CloudProject] = []

    // MARK: Saved templates (global, persisted to ~/.jaca)

    private(set) var queryTemplates: [CloudQueryTemplate] = []
    private(set) var sqlTemplates: [CloudSqlTemplate] = []

    var toast: CloudLoggingToast?
    private var toastTask: Task<Void, Never>?

    private let store: CloudProjectStore
    private let templateStore: CloudTemplateStore

    init(store: CloudProjectStore = CloudProjectStore(), templateStore: CloudTemplateStore = CloudTemplateStore()) {
        self.store = store
        self.templateStore = templateStore
        projects = store.load()   // synchronous load → first frame already has the project list
        (queryTemplates, sqlTemplates) = templateStore.load()
        detect()
    }

    // MARK: - Templates

    func saveQueryTemplate(name: String, query: CloudLogQuery, rawFilter: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queryTemplates.append(CloudQueryTemplate(name: trimmed, query: query, rawFilter: rawFilter))
        templateStore.save(queries: queryTemplates, sql: sqlTemplates)
        flash("Saved query template")
    }

    func deleteQueryTemplate(_ id: UUID) {
        queryTemplates.removeAll { $0.id == id }
        templateStore.save(queries: queryTemplates, sql: sqlTemplates)
    }

    func saveSqlTemplate(name: String, sql: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sqlTemplates.append(CloudSqlTemplate(name: trimmed, sql: sql))
        templateStore.save(queries: queryTemplates, sql: sqlTemplates)
        flash("Saved SQL template")
    }

    func deleteSqlTemplate(_ id: UUID) {
        sqlTemplates.removeAll { $0.id == id }
        templateStore.save(queries: queryTemplates, sql: sqlTemplates)
    }

    // MARK: - Detection & auth

    /// (Re)detects gcloud, then refreshes the auth state. Safe to call repeatedly.
    func detect() {
        isDetecting = true
        Task { @MainActor in
            let url = await GcloudToolchain.resolveBinaryURL()
            self.binaryURL = url
            self.isDetecting = false
            if url == nil { self.authState = .notInstalled; return }
            await self.refreshAuth()
        }
    }

    func refreshAuth() async {
        guard let cli else { authState = .notInstalled; return }
        if let account = await cli.activeAccount() {
            authState = .authenticated(account: account)
        } else {
            authState = .notAuthenticated
        }
    }

    /// Flips to "not signed in" when a session's gcloud call reports an auth failure.
    func markUnauthenticated() { authState = .notAuthenticated }

    // MARK: - Lookup

    func project(_ id: String) -> CloudProject? { projects.first { $0.projectID == id } }

    // MARK: - Mutations (persist + notify reactively via @Observable)

    enum AddResult: Equatable { case added, alreadyExists, failure(String) }

    /// Validates the project id via `gcloud projects describe`, then stores it (req 3).
    func addProject(id: String, displayName: String) async -> AddResult {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("Enter a project id.") }
        if projects.contains(where: { $0.projectID == trimmed }) { return .alreadyExists }
        guard let cli else { return .failure("gcloud isn't installed.") }
        do {
            try await cli.describeProject(trimmed)
        } catch let error as GcloudCLI.CLIError {
            if case .notAuthenticated = error { authState = .notAuthenticated }
            return .failure(error.errorDescription ?? "Couldn't validate the project.")
        } catch {
            return .failure(error.localizedDescription)
        }
        var project = CloudProject(projectID: trimmed)
        project.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        projects.append(project)
        persist()
        flash("Added \(project.title)")
        return .added
    }

    func setDisplayName(_ name: String, for id: String) {
        update(id) { $0.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        flash("Renamed")
    }

    func removeProject(_ id: String) {
        let title = project(id)?.title ?? id
        projects.removeAll { $0.projectID == id }
        persist()
        flash("Removed \(title)", fallback: "eraser")
    }

    /// Sets the GLOBAL selected log name for a project — shared by every open session (req 7).
    func setSelectedLogName(_ logName: String?, for id: String) {
        update(id) { $0.selectedLogName = logName }
    }

    func setLogNames(_ names: [String], for id: String) {
        update(id) { $0.logNames = names }
    }

    /// Refreshes the available log names from gcloud and caches them (req 7).
    func refreshLogNames(for id: String) async {
        guard let cli else { return }
        do {
            let names = try await cli.listLogNames(project: id)
            setLogNames(names, for: id)
        } catch let error as GcloudCLI.CLIError {
            if case .notAuthenticated = error { authState = .notAuthenticated }
            flash(error.errorDescription ?? "Couldn't list logs.", fallback: "warn")
        } catch {
            flash("Couldn't list logs.", fallback: "warn")
        }
    }

    /// Merges auto-detected label keys for a (project, log name). Only persists on a real
    /// change, so the hot streaming path doesn't thrash the disk (req 9.3).
    func recordLabelKeys(_ keys: Set<String>, project id: String, logName: String) {
        guard !keys.isEmpty, let index = projects.firstIndex(where: { $0.projectID == id }) else { return }
        let existing = projects[index].labelKeysByLogName[logName] ?? []
        let (merged, changed) = LabelDetector.merge(existing, with: keys)
        guard changed else { return }
        projects[index].labelKeysByLogName[logName] = merged
        persist()
    }

    // MARK: - Toast

    func flash(_ message: String, fallback: String = "checkmark") {
        toastTask?.cancel()
        toast = CloudLoggingToast(message: message, systemFallback: fallback)
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2_600))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: - Internals

    private func update(_ id: String, _ change: (inout CloudProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.projectID == id }) else { return }
        change(&projects[index])
        persist()
    }

    private func persist() { store.save(projects) }
}
