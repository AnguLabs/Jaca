import Foundation
import Observation

/// Thread-safe hand-off buffer between the background poll consumer and the main-actor flush
/// loop (the `CloudLogEntry` analogue of `LineBuffer`).
final class CloudEntryBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [CloudLogEntry] = []

    func append(_ batch: [CloudLogEntry]) {
        lock.lock(); entries.append(contentsOf: batch); lock.unlock()
    }

    func drain(max: Int) -> [CloudLogEntry] {
        lock.lock(); defer { lock.unlock() }
        if entries.count <= max {
            let out = entries
            entries.removeAll(keepingCapacity: true)
            return out
        }
        let out = Array(entries.prefix(max))
        entries.removeFirst(max)
        return out
    }
}

/// The config for a forked session: a starting query (or raw filter) + a suggested tab name.
struct CloudSessionFork {
    var query: CloudLogQuery
    var rawFilter: String?
    var name: String
}

/// One Cloud Logging investigation tab. Streams a project's logs via interval polling
/// (`CloudLogPoller`), buffers entries off-main and coalesces them into the observed `visible`
/// slice on a ~30ms timer (the same buffer→flush→ring→background-filter pipeline as
/// `LogSession`, so the list stays smooth under bursty logs — req 10). The **server-side** query
/// (logName, time range, severity/text/label clauses) narrows the gcloud stream and restarts
/// the poll on change; the **client-side** `searchText` filters the in-memory buffer instantly.
/// Every entry is also written to a per-session SQLite DB for the SQL mode (reqs 13–14).
@MainActor
@Observable
final class CloudLogSession: WorkspaceTab {
    let id = UUID()
    var displayName: String { didSet { onStateChanged?() } }
    let projectID: String
    /// Read for the GLOBAL per-project state (selected log name, detected label keys). Strong
    /// ref is safe: the registry never holds sessions, so there's no cycle.
    let registry: CloudLoggingRegistry

    var onStateChanged: (() -> Void)?

    enum ViewMode: String { case logs, sql }
    var viewMode: ViewMode = .logs

    /// The per-session structured filter (server-side). Persisted on change.
    var query: CloudLogQuery { didSet { onStateChanged?() } }
    /// The per-session time window (server-side). Persisted on change.
    var timeRange: CloudTimeRange { didSet { onStateChanged?() } }
    /// Instant, client-side search over the already-fetched buffer.
    var searchText = "" { didSet { searchChanged() } }
    /// A raw Cloud Logging filter ingested from a Logs Explorer URL. When set, it overrides the
    /// structured `query` for fetching (the URL is authoritative). Persisted on change.
    var rawFilter: String? { didSet { onStateChanged?() } }

    private(set) var isRunning = false
    private(set) var isLoading = false      // backfill query in flight
    var statusMessage: String?

    // MARK: Rendering pipeline (mirrors LogSession)

    private(set) var visible: [CloudLogEntry] = []
    private(set) var displayMap = DisplayLineMap()
    private(set) var droppedDisplayRows = 0
    private(set) var totalCount = 0
    private(set) var droppedCount = 0
    private(set) var listEpoch = 0
    var followTail = true
    var scrollTarget: UInt64?

    /// The entry shown in the right-side detail panel (req 11). nil = panel closed.
    var selectedEntry: CloudLogEntry?

    // MARK: SQL mode (reqs 13–14) — a live second filter layer over the captured rows.

    var sqlText = CloudSqlTemplates.recent
    var sqlError: String?
    var sqlRunning = false
    /// How many log rows the current SQL query maps to in the list (shown in the editor bar).
    private(set) var sqlMatchCount = 0
    /// The SQL result rows' keys, **in result order**: `insert_id` (primary) and `seq` (fallback)
    /// per row. The SQL-mode list is rebuilt by looking each key up in the ring, so the query's
    /// LIMIT / ORDER BY / WHERE are reflected exactly. We key on `insert_id` because it is
    /// identical in the ring and the DB even after a poll restart, where `seq` is re-stamped on
    /// the ring but kept by the DB (INSERT OR IGNORE). nil = no SQL filter (Logs mode).
    private var sqlOrderedIds: [String]?
    private var sqlOrderedSeqs: [UInt64]?
    /// Whether a SQL filter is currently driving the list.
    private var sqlActive: Bool { sqlOrderedIds != nil || sqlOrderedSeqs != nil }
    /// Guards against overlapping SQL runs (the manual Run racing the 2s live refresh): a run in
    /// flight sets this, and a request arriving meanwhile is coalesced into one re-run when it
    /// finishes — so the button never sticks on "Running…".
    private var sqlQueryInFlight = false
    private var sqlRerunRequested = false
    /// True once the user hand-edits the SQL, so mode switches stop auto-regenerating it.
    private var sqlCustomized = false
    private var lastGeneratedSql: String?
    private var sqlRefreshTask: Task<Void, Never>?

    private var ring: [CloudLogEntry] = []
    private let ringCap = 500_000
    private let maxPerFlush = 4_000
    private var recomputeToken = 0

    private let pending = CloudEntryBuffer()
    private let seq = SeqCounter()
    private var consumeTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    /// Holding the stream keeps the poller alive; dropping/cancelling it stops the poll.
    private var pollStream: AsyncStream<CloudPollEvent>?

    private var database: CloudLogDatabase?

    init(
        projectID: String,
        registry: CloudLoggingRegistry,
        displayName: String? = nil,
        query: CloudLogQuery = CloudLogQuery(),
        timeRange: CloudTimeRange = .last(minutes: 15),
        rawFilter: String? = nil
    ) {
        self.projectID = projectID
        self.registry = registry
        self.query = query
        self.timeRange = timeRange
        self.rawFilter = rawFilter
        self.displayName = displayName ?? (registry.project(projectID)?.title ?? projectID)
    }

    // MARK: - Derived (read from the registry, reactively)

    var projectTitle: String { registry.project(projectID)?.title ?? projectID }
    var selectedLogName: String? { registry.project(projectID)?.selectedLogName }
    var labelKeys: [String] { registry.project(projectID)?.currentLabelKeys ?? [] }
    var favoriteLabelKeys: [String] { registry.project(projectID)?.currentFavoriteLabelKeys ?? [] }
    /// Detected label keys with favorites pinned to the top — what the picker presents.
    var orderedLabelKeys: [String] { CloudLabelOrdering.ordered(keys: labelKeys, favorites: favoriteLabelKeys) }

    func isFavoriteLabel(_ key: String) -> Bool { favoriteLabelKeys.contains(key) }
    func toggleFavoriteLabel(_ key: String) {
        registry.toggleFavoriteLabel(key, project: projectID, logName: selectedLogName ?? "")
    }

    var subtitle: String {
        var parts = [projectTitle]
        if rawFilter != nil { parts.append("URL filter") }
        else if let logName = selectedLogName { parts.append(CloudLogName.shortId(logName)) }
        parts.append(timeRange.label)
        if sqlActive { parts.append("SQL") }
        else if rawFilter == nil && !query.isEmpty { parts.append("filtered") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Display rows (multi-line messages)

    var displayRowCount: Int { displayMap.totalRows }
    func locate(displayRow row: Int) -> (log: Int, sub: Int) { displayMap.locate(row: row) }
    func firstDisplayRow(ofLog i: Int) -> Int { displayMap.firstRow(ofLog: i) }
    func displayRowRange(ofLog i: Int) -> ClosedRange<Int> { displayMap.rows(ofLog: i) }
    func displayMessage(_ entry: CloudLogEntry) -> String { entry.message }

    func logIndices(forDisplayRows rows: IndexSet) -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        for r in rows where r < displayMap.totalRows {
            let li = displayMap.locate(row: r).log
            if seen.insert(li).inserted { out.append(li) }
        }
        return out
    }

    // MARK: - Lifecycle

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }
        guard let cli = registry.cli else {
            statusMessage = "gcloud isn't installed."
            return
        }
        isRunning = true
        isLoading = true
        statusMessage = nil
        if database == nil { database = CloudLogDatabase(sessionID: id) }

        let logName = selectedLogName
        let poller = CloudLogPoller(
            cli: cli, project: projectID, logName: logName, query: query,
            timeRange: timeRange, rawFilter: rawFilter
        )
        let stream = poller.stream()
        pollStream = stream
        startFlushLoop()
        consumeTask = Task { [weak self] in await self?.consume(stream) }
        onStateChanged?()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        isLoading = false
        consumeTask?.cancel(); consumeTask = nil    // cancels the poller via the stream's onTermination
        flushTask?.cancel(); flushTask = nil
        pollStream = nil
        flush(max: .max)                              // drain anything left
        onStateChanged?()
    }

    /// Re-applies the server-side query/time/logName by restarting the poll (these narrow the
    /// gcloud-side stream, so they can't be applied to the already-fetched buffer). No-op when
    /// stopped — the new query is used on the next Start.
    func applyServerQuery() {
        guard isRunning else { return }
        stop()
        clear()
        start()
    }

    /// Called by the view when the GLOBAL (registry) log name changes for this project, so a
    /// running session re-targets the new bucket reactively (req 7).
    func logNameChanged() { if isRunning { applyServerQuery() } }

    /// Clears the in-app scrollback (does not touch Cloud Logging or the SQLite DB).
    func clear() {
        recomputeToken &+= 1
        ring.removeAll(keepingCapacity: true)
        visible.removeAll(keepingCapacity: true)
        displayMap.removeAll()
        totalCount = 0
        droppedCount = 0
        droppedDisplayRows = 0
        selectedEntry = nil
        listEpoch &+= 1
    }

    /// Stops, then deletes the per-session SQLite file. Called by AppModel on tab close.
    func dispose() {
        sqlRefreshTask?.cancel(); sqlRefreshTask = nil
        stop()
        let db = database
        database = nil
        Task { await db?.deleteFile() }
    }

    // MARK: - Stream consumption

    private func consume(_ stream: AsyncStream<CloudPollEvent>) async {
        let buffer = pending, counter = seq
        for await event in stream {
            switch event {
            case .batch(let entries):
                var stamped = entries
                for i in stamped.indices { stamped[i].seq = counter.next() }
                buffer.append(stamped)
            case .caughtUp:
                isLoading = false
            case .error(let error):
                statusMessage = error.errorDescription
                isLoading = false
                if case .notAuthenticated = error { registry.markUnauthenticated() }
            }
        }
        isLoading = false
    }

    private func startFlushLoop() {
        flushTask = Task { [weak self] in
            while let self, self.isRunning, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                self.flush()
            }
        }
    }

    private func flush(max: Int = 4_000) {
        let drained = pending.drain(max: max)
        guard !drained.isEmpty else { return }

        // Persist to the per-session SQLite (off main) for the SQL mode.
        if let database {
            Task { await database.appendEntries(drained) }
        }
        // Auto-detect label keys → registry (cached globally per project + log name, req 9.3).
        // Keyed by the selected log name, or "" (project-wide) when none is selected, so the
        // labels system populates regardless.
        registry.recordLabelKeys(LabelDetector.keys(in: drained),
                                 project: projectID, logName: selectedLogName ?? "")

        ring.append(contentsOf: drained)
        totalCount += drained.count

        if ring.count > ringCap {
            let overflow = ring.count - ringCap
            ring.removeFirst(overflow)
            droppedCount += overflow
            let minSeq = ring.first?.seq ?? 0
            var drop = 0
            while drop < visible.count && visible[drop].seq < minSeq { drop += 1 }
            if drop > 0 {
                visible.removeFirst(drop)
                droppedDisplayRows += displayMap.removeFirst(drop)
            }
        }

        // In SQL mode the query owns the list; the 2s live refresh rebuilds it from the new rows.
        guard viewMode != .sql else { return }
        for entry in drained where passes(entry) {
            visible.append(entry)
            displayMap.append(lineCount: LogTextLines.count(entry.message))
        }
    }

    /// Whether a new streamed entry should append to the live list — only in Logs mode (in SQL
    /// mode the query owns the list and rebuilds it on each refresh) and only if it matches the
    /// instant client search.
    private func passes(_ entry: CloudLogEntry) -> Bool {
        Self.matches(entry, search: searchText)
    }

    /// Routes a client-search change to the right list: rebuild from the SQL result in SQL mode,
    /// re-filter the ring in Logs mode.
    private func searchChanged() {
        if viewMode == .sql { rebuildSqlVisible() } else { recomputeVisible() }
    }

    /// Re-filters the whole ring off the main thread on a search change, then assigns on main
    /// (token discards stale results; a catch-up pass re-adds entries that streamed in while the
    /// background filter ran). Same shape as `LogSession.recomputeVisible`. Logs mode only.
    private func recomputeVisible() {
        recomputeToken &+= 1
        let token = recomputeToken
        let snapshot = ring
        let search = searchText
        let lastSeq = snapshot.last?.seq
        Task.detached(priority: .userInitiated) {
            let result = snapshot.filter { Self.matches($0, search: search) }
            await MainActor.run { [weak self] in
                guard let self, token == self.recomputeToken else { return }
                var out = result
                if let lastSeq {
                    for entry in self.ring where entry.seq > lastSeq && self.passes(entry) {
                        out.append(entry)
                    }
                }
                self.visible = out
                self.displayMap.rebuild(lineCounts: out.map { LogTextLines.count($0.message) })
                self.listEpoch &+= 1
            }
        }
    }

    /// Rebuilds the SQL-mode list from the last SQL result: each result row (in query order) is
    /// resolved to a ring entry by `insert_id`, falling back to `seq`, then run through the instant
    /// search. The list is therefore exactly what the query returned (LIMIT / ORDER BY / WHERE),
    /// not a fuzzy membership test — which is why a `LIMIT 2` now shows two rows. Off-main (token
    /// shared with `recomputeVisible`, so the latest of either wins).
    private func rebuildSqlVisible() {
        guard viewMode == .sql, sqlActive else { return }
        recomputeToken &+= 1
        let token = recomputeToken
        let ids = sqlOrderedIds
        let seqs = sqlOrderedSeqs
        let snapshot = ring
        let search = searchText
        Task.detached(priority: .userInitiated) {
            let count = ids?.count ?? seqs?.count ?? 0
            var byId = [String: CloudLogEntry](minimumCapacity: snapshot.count)
            var bySeq = [UInt64: CloudLogEntry](minimumCapacity: snapshot.count)
            for e in snapshot {
                if !e.insertId.isEmpty { byId[e.insertId] = e }
                bySeq[e.seq] = e
            }
            var out: [CloudLogEntry] = []
            out.reserveCapacity(count)
            var seen = Set<UInt64>()
            for i in 0..<count {
                var entry: CloudLogEntry?
                if let id = ids?[i], !id.isEmpty { entry = byId[id] }
                if entry == nil, let s = seqs?[i] { entry = bySeq[s] }
                guard let e = entry, seen.insert(e.seq).inserted, Self.matches(e, search: search) else { continue }
                out.append(e)
            }
            await MainActor.run { [weak self] in
                guard let self, token == self.recomputeToken else { return }
                self.visible = out
                self.displayMap.rebuild(lineCounts: out.map { LogTextLines.count($0.message) })
                self.listEpoch &+= 1
                self.sqlMatchCount = out.count
            }
        }
    }

    /// Instant client-side match: free text over message, log id, severity, and label keys/values.
    nonisolated static func matches(_ entry: CloudLogEntry, search: String) -> Bool {
        guard !search.isEmpty else { return true }
        if entry.message.range(of: search, options: .caseInsensitive) != nil { return true }
        if entry.logId.range(of: search, options: .caseInsensitive) != nil { return true }
        if entry.severity.apiName.range(of: search, options: .caseInsensitive) != nil { return true }
        for (key, value) in entry.labels {
            if key.range(of: search, options: .caseInsensitive) != nil { return true }
            if value.range(of: search, options: .caseInsensitive) != nil { return true }
        }
        return false
    }

    // MARK: - Detail-panel filter actions (req 12)

    /// Replaces any existing condition for this label with an exact match, then restarts.
    func filterByLabel(scope: LabelScope, key: String, value: String) {
        query.labelConditions.removeAll { $0.scope == scope && $0.key == key }
        query.labelConditions.append(LabelCondition(key: key, scope: scope, mode: .exact, value: value))
        applyServerQuery()
    }

    /// Appends another exact match for this label and OR-combines them, then restarts.
    func orLabel(scope: LabelScope, key: String, value: String) {
        query.labelConditions.append(LabelCondition(key: key, scope: scope, mode: .exact, value: value))
        query.labelCombineOr = true
        applyServerQuery()
    }

    func filterBySeverity(_ severity: CloudSeverity) {
        query.severitySet = [severity]
        applyServerQuery()
    }

    // MARK: - Fork into a NEW session (branch into one entity without losing your place)

    /// Builds the config for a new session that keeps THIS session's filter and adds an exact
    /// label match — e.g. click a user id to open a tab scoped to that user, current tab intact.
    func forkAddingLabel(scope: LabelScope, key: String, value: String) -> CloudSessionFork {
        let name = Self.shortName("\(key)=\(value)")
        if let raw = rawFilter, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let term = "\(scope.field(for: key))=\(CloudFilter.quote(value))"
            return CloudSessionFork(query: CloudLogQuery(), rawFilter: "(\(raw)) AND \(term)", name: name)
        }
        var forked = query
        forked.labelConditions.removeAll { $0.scope == scope && $0.key == key }
        forked.labelConditions.append(LabelCondition(key: key, scope: scope, mode: .exact, value: value))
        return CloudSessionFork(query: forked, rawFilter: nil, name: name)
    }

    func forkAddingSeverity(_ severity: CloudSeverity) -> CloudSessionFork {
        if let raw = rawFilter, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            return CloudSessionFork(query: CloudLogQuery(),
                                    rawFilter: "(\(raw)) AND severity=\(severity.apiName)", name: severity.name)
        }
        var forked = query
        forked.severitySet = [severity]
        return CloudSessionFork(query: forked, rawFilter: nil, name: severity.name)
    }

    private static func shortName(_ s: String) -> String {
        s.count > 28 ? String(s.prefix(28)) + "…" : s
    }

    // MARK: - SQL mode (reqs 13–14): a live, query-language-powered filter ON the log list.

    /// Switches between the live log list and the SQL-filtered list. Returning to `.logs` removes
    /// the SQL filter (the captured logs themselves are never lost).
    func setViewMode(_ mode: ViewMode) {
        guard viewMode != mode else { return }
        viewMode = mode
        if mode == .sql {
            if !sqlCustomized { regenerateSQL() }
            runSQL()
            startSqlAutoRefresh()
        } else {
            sqlRefreshTask?.cancel(); sqlRefreshTask = nil
            sqlOrderedIds = nil
            sqlOrderedSeqs = nil
            sqlRunning = false
            sqlError = nil
            recomputeVisible()          // drop the SQL filter → show the full live logs again
        }
    }

    /// Called by the SQL editor when its text changes, so mode switches stop auto-regenerating
    /// once the user has hand-edited (or picked a template).
    func noteSqlTextChanged(_ text: String) { sqlCustomized = (text != lastGeneratedSql) }

    /// (Re)builds a SQL starting point mirroring the current configuration: the structured
    /// (level-1) query is already baked into the captured rows, so this selects them, keeps an
    /// `insert_id` column (so matching rows can be shown in the list — stable across poll
    /// restarts, unlike `seq`), and documents the active filter.
    func regenerateSQL() {
        let generated = generatedSQL()
        lastGeneratedSql = generated
        sqlText = generated
        sqlCustomized = false
    }

    func applySqlText(_ text: String) {
        sqlText = text
        noteSqlTextChanged(text)
        runSQL()
    }

    private func generatedSQL() -> String {
        let serverFilter = CloudFilter.build(logName: selectedLogName, time: nil, query: query, rawFilter: rawFilter)
        var lines: [String] = []
        lines.append("-- Level 1 (Cloud Logging filter, fetched live): \(serverFilter.isEmpty ? "(all logs)" : serverFilter)")
        lines.append("-- Level 2 (SQL filter): keep `insert_id`; the matching rows show in the list, in this order.")
        lines.append("SELECT insert_id, seq, datetime(ts, 'unixepoch', 'localtime') AS time, severity_name, log_id, text_payload")
        lines.append("FROM log_entry")
        lines.append("ORDER BY seq DESC")
        lines.append("LIMIT 1000;")
        return lines.joined(separator: "\n")
    }

    private func startSqlAutoRefresh() {
        sqlRefreshTask?.cancel()
        sqlRefreshTask = Task { [weak self] in
            while let self, self.viewMode == .sql, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled || self.viewMode != .sql { break }
                self.runSQL(live: true)
            }
        }
    }

    /// Runs the SQL and drives the log list from its result rows (in query order). `live` re-runs
    /// (from the 2s auto-refresh) stay quiet — no spinner, no clearing errors. Overlapping runs are
    /// coalesced so the manual Run can never stick on "Running…".
    func runSQL(live: Bool = false) {
        guard let database else {
            if !live { sqlError = "No data captured yet — start the session first."; sqlRunning = false }
            return
        }
        let sql = sqlText
        guard DatabaseService.isReadOnly(sql) else {
            if !live { sqlError = "Only read-only queries are allowed (SELECT / WITH / PRAGMA / EXPLAIN)."; sqlRunning = false }
            return
        }
        // Coalesce: if a run is already in flight, remember to re-run once it lands instead of
        // piling up another query on the DB actor (and leaving the button spinning).
        if sqlQueryInFlight {
            sqlRerunRequested = true
            if !live { sqlRunning = true; sqlError = nil }
            return
        }
        sqlQueryInFlight = true
        if !live { sqlRunning = true; sqlError = nil }
        Task { [weak self] in   // inherits MainActor isolation; query hops to the DB actor and back
            defer { self?.finishSqlRun() }
            do {
                let rs = try await database.query(sql)   // writer connection → sees live inserts
                guard let self else { return }
                self.applySqlResult(rs)
            } catch {
                guard let self else { return }
                self.sqlError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    /// Captures the SQL result's row keys (insert_id + seq, in order) and rebuilds the list.
    private func applySqlResult(_ rs: DBResultSet) {
        let idCol = rs.columns.firstIndex { $0.lowercased() == "insert_id" }
        let seqCol = rs.columns.firstIndex { $0.lowercased() == "seq" }
        guard idCol != nil || seqCol != nil else {
            sqlError = "Your SQL must SELECT an `insert_id` (or `seq`) column so the matching logs can be shown — e.g. SELECT insert_id, … FROM log_entry …"
            sqlOrderedIds = []
            sqlOrderedSeqs = nil
            sqlMatchCount = 0
            rebuildSqlVisible()
            return
        }
        sqlOrderedIds = idCol.map { col in rs.rows.map { $0[col] ?? "" } }
        sqlOrderedSeqs = seqCol.map { col in rs.rows.map { UInt64($0[col] ?? "") ?? 0 } }
        sqlError = nil
        rebuildSqlVisible()
    }

    /// Clears the in-flight flag and runs once more if a request arrived mid-run (so the latest
    /// edits aren't lost), guaranteeing the spinner always resolves.
    private func finishSqlRun() {
        sqlQueryInFlight = false
        sqlRunning = false
        if sqlRerunRequested {
            sqlRerunRequested = false
            if viewMode == .sql { runSQL(live: true) }   // quiet re-run with the latest text
        }
    }

    // MARK: - Share (Logs Explorer URL)

    /// A shareable Cloud Console Logs Explorer URL for this session's current filter.
    func consoleURL() -> String {
        let filter = CloudFilter.build(logName: selectedLogName, time: nil, query: query, rawFilter: rawFilter)
        return CloudConsoleURL.build(project: projectID, filter: filter)
    }

    // MARK: - Export

    func exportText() -> String {
        visible.map { $0.raw }.joined(separator: "\n")
    }
}

/// Ready-made SQL snippets the SQL mode offers (req 14). The "flow window" template is the
/// headline use case: bracket rows between a START match and the next END match so you can
/// isolate a single user/session flow in a noisy log.
enum CloudSqlTemplates {
    static let recent = """
    SELECT insert_id, seq, datetime(ts, 'unixepoch', 'localtime') AS time, severity_name, log_id, text_payload
    FROM log_entry
    ORDER BY seq DESC
    LIMIT 1000;
    """

    static let errorsOnly = """
    SELECT insert_id, seq, datetime(ts, 'unixepoch', 'localtime') AS time, severity_name, text_payload
    FROM log_entry
    WHERE severity >= 500          -- ERROR and above
    ORDER BY seq DESC
    LIMIT 500;
    """

    static let flowWindow = """
    -- Flow window (req 14): keep only rows inside a START…END bracket — isolate one flow.
    -- Edit the two LIKE patterns to your flow's start/end markers, then Run.
    WITH marked AS (
      SELECT *,
        MAX(CASE WHEN text_payload LIKE '%START%' THEN seq END) OVER (ORDER BY seq) AS last_start,
        MAX(CASE WHEN text_payload LIKE '%END%'   THEN seq END) OVER (ORDER BY seq) AS last_end
      FROM log_entry
    )
    SELECT insert_id, seq, datetime(ts, 'unixepoch', 'localtime') AS time, severity_name, text_payload
    FROM marked
    WHERE last_start IS NOT NULL
      AND (last_end IS NULL OR last_end < last_start)   -- inside an open START…END bracket
    ORDER BY seq;
    """

    static let all: [(label: String, sql: String)] = [
        ("Recent 1000", recent),
        ("Errors only", errorsOnly),
        ("Flow window (START…END)", flowWindow),
    ]
}
