import Foundation
import Observation

/// One "Database" tab: pick an app on the device, pick one of its SQLite databases,
/// then browse tables/rows (paginated) and run read-only queries. The browsed data is a
/// snapshot of a pulled copy — `refresh()` re-pulls. Conforms to `WorkspaceTab` so it
/// rides the same tab strip as log/network sessions.
@MainActor
@Observable
final class DatabaseSession: WorkspaceTab {
    let id = UUID()
    var displayName: String
    let device: Device
    var subtitle: String { appID.map { shortName($0) } ?? "Pick an app" }
    var isRunning: Bool { false }
    func stop() { cleanup() }

    // Flow
    private(set) var apps: [AppEntry] = []
    private(set) var appID: String?
    private(set) var databases: [RemoteDB] = []
    private(set) var selectedDB: RemoteDB?
    private(set) var tables: [DBTable] = []
    private(set) var selectedTable: String?
    private(set) var result: DBResultSet?
    private(set) var selectedRow: Int?
    private(set) var loading = false
    var error: String?
    var sqlText = ""

    func selectRow(_ index: Int?) { selectedRow = index }

    // Pagination (table browse)
    private(set) var page = 0
    let pageSize = 100
    var hasNextPage: Bool { (result?.rows.count ?? 0) == pageSize }

    private let service: DatabaseService
    private let adbURL: URL?
    private var localDB: URL?

    init(device: Device, adbURL: URL?) {
        self.device = device
        self.adbURL = adbURL
        self.service = DatabaseService(adbURL: adbURL)
        self.displayName = "DB · \(device.model)"
        loadApps()
    }

    // MARK: - Apps

    func loadApps() {
        loading = true; error = nil
        let device = device, adbURL = adbURL
        Task { [weak self] in
            let list = await InstalledApps.list(for: device, adbURL: adbURL)
            guard let self else { return }
            self.apps = list.sorted { ($0.isUserApp ? 0 : 1, $0.display.lowercased()) < ($1.isUserApp ? 0 : 1, $1.display.lowercased()) }
            self.loading = false
        }
    }

    func selectApp(_ id: String) {
        appID = id
        displayName = "DB · \(shortName(id))"
        databases = []; selectedDB = nil; tables = []; selectedTable = nil; result = nil
        listDatabases()
    }

    // MARK: - Databases

    func listDatabases() {
        guard let appID else { return }
        loading = true; error = nil
        let service = service, device = device
        Task { [weak self] in
            do {
                let dbs = try await service.listDatabases(device: device, appID: appID)
                guard let self else { return }
                self.databases = dbs
                self.loading = false
                if dbs.isEmpty { self.error = "No SQLite database found for this app." }
                else { self.selectDatabase(dbs[0]) }
            } catch {
                guard let self else { return }
                self.loading = false
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    func selectDatabase(_ db: RemoteDB) {
        selectedDB = db
        tables = []; selectedTable = nil; result = nil
        pullAndLoad()
    }

    /// Re-pulls the selected database and reloads tables (the "Refresh" action).
    func refresh() { if selectedDB != nil { pullAndLoad() } else { listDatabases() } }

    private func pullAndLoad() {
        guard let db = selectedDB, let appID else { return }
        loading = true; error = nil
        let service = service, device = device
        Task { [weak self] in
            do {
                let local = try await service.pull(device: device, db: db, appID: appID)
                let tbls = try await Task.detached { try service.tables(localDB: local) }.value
                guard let self else { return }
                self.cleanup()
                self.localDB = local
                self.tables = tbls
                self.loading = false
                if let first = tbls.first { self.selectTable(first.name) }
            } catch {
                guard let self else { return }
                self.loading = false
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    // MARK: - Rows / query

    func selectTable(_ name: String) {
        selectedTable = name
        page = 0
        sqlText = "SELECT * FROM \"\(name)\""
        loadRows()
    }

    private func loadRows() {
        guard let local = localDB, let table = selectedTable else { return }
        loading = true; error = nil
        let service = service, page = page, size = pageSize
        Task { [weak self] in
            do {
                let rs = try await Task.detached { try service.rows(localDB: local, table: table, limit: size, offset: page * size) }.value
                guard let self else { return }
                self.result = rs; self.selectedRow = nil; self.loading = false
            } catch {
                guard let self else { return }
                self.loading = false
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    func nextPage() { if hasNextPage { page += 1; loadRows() } }
    func prevPage() { if page > 0 { page -= 1; loadRows() } }

    /// Runs the SQL box read-only; the read-only handle is the hard guard, this is the hint.
    func runQuery() {
        guard let local = localDB else { return }
        let sql = sqlText
        guard DatabaseService.isReadOnly(sql) else { error = DBError.readOnly.errorDescription; return }
        loading = true; error = nil; selectedTable = nil
        let service = service
        Task { [weak self] in
            do {
                let rs = try await Task.detached { try service.query(localDB: local, sql: sql) }.value
                guard let self else { return }
                self.result = rs; self.selectedRow = nil; self.loading = false
            } catch {
                guard let self else { return }
                self.loading = false
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    // MARK: - Cleanup

    private func cleanup() {
        if let dir = localDB?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: dir) }
        localDB = nil
    }

    private func shortName(_ id: String) -> String {
        if let app = apps.first(where: { $0.id == id }), let n = app.name { return n }
        return (id as NSString).pathComponents.last ?? id
    }
}
