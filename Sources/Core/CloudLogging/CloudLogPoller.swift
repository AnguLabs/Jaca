import Foundation

/// What the poller surfaces to the session.
enum CloudPollEvent: Sendable {
    case batch([CloudLogEntry])
    case error(GcloudCLI.CLIError)
    /// Emitted once the live backfill (or the whole absolute-range fetch) has completed,
    /// so the UI can drop the initial "loading…" state.
    case caughtUp
}

/// Sliding-window dedup by `insertId`. The poll cursor uses `timestamp >=` (so the boundary
/// second is re-fetched and nothing is missed), and this drops the re-seen entries. Bounded
/// so memory stays flat over a long session. Pure → unit-tested.
struct InsertIdWindow {
    private var seen: Set<String> = []
    private var order: [String] = []
    private let cap: Int

    init(cap: Int = 5_000) { self.cap = cap }

    /// Returns only the entries not seen before, recording their ids. Entries with an empty
    /// `insertId` always pass (they can't be deduped).
    mutating func fresh(_ entries: [CloudLogEntry]) -> [CloudLogEntry] {
        var out: [CloudLogEntry] = []
        out.reserveCapacity(entries.count)
        for e in entries {
            if e.insertId.isEmpty {
                out.append(e)
            } else if seen.insert(e.insertId).inserted {
                order.append(e.insertId)
                out.append(e)
            }
        }
        if order.count > cap {
            let remove = order.count - cap
            for id in order.prefix(remove) { seen.remove(id) }
            order.removeFirst(remove)
        }
        return out
    }
}

/// Streams Cloud Logging via interval polling (gcloud has no `--follow`): backfill the
/// selected window once, then re-`read` every `interval` seconds with an advancing
/// `timestamp` cursor + `insertId` dedup. Absolute ranges are a single fetch. The work
/// runs in a `Task` owned by the returned `AsyncStream`; cancelling the stream stops it.
struct CloudLogPoller: Sendable {
    let cli: GcloudCLI
    let project: String
    /// Full log name (`projects/<id>/logs/<encoded>`) or nil for all logs.
    let logName: String?
    let query: CloudLogQuery
    let timeRange: CloudTimeRange
    /// A raw filter (from a Logs Explorer URL) that overrides `query`/`logName` when set.
    var rawFilter: String? = nil
    var interval: TimeInterval = 4
    var backfillLimit: Int = 1_000
    var pollLimit: Int = 1_000

    func stream() -> AsyncStream<CloudPollEvent> {
        AsyncStream { continuation in
            let task = Task { await run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ cont: AsyncStream<CloudPollEvent>.Continuation) async {
        let now = Date()
        var dedup = InsertIdWindow()
        var cursor = timeRange.start(now: now)

        // 1. Backfill the selected window once (also the whole fetch for absolute ranges).
        let backfillFilter = CloudFilter.build(logName: logName, time: timeRange.clause(now: now), query: query, rawFilter: rawFilter)
        do {
            let entries = try await cli.read(project: project, filter: backfillFilter, order: "asc", limit: backfillLimit)
            let fresh = dedup.fresh(entries)
            if !fresh.isEmpty {
                cont.yield(.batch(fresh))
                cursor = max(cursor, fresh.map(\.timestamp).max() ?? cursor)
            }
        } catch let error as GcloudCLI.CLIError {
            cont.yield(.error(error))
        } catch {
            cont.yield(.error(.failed(error.localizedDescription)))
        }

        cont.yield(.caughtUp)

        guard timeRange.isLive else { cont.finish(); return }

        // 2. Poll forward.
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { break }
            let filter = CloudFilter.build(
                logName: logName,
                time: "timestamp>=\(CloudTimestamp.quote(cursor))",
                query: query,
                rawFilter: rawFilter
            )
            do {
                let entries = try await cli.read(project: project, filter: filter, order: "asc", limit: pollLimit)
                let fresh = dedup.fresh(entries)
                if !fresh.isEmpty {
                    cont.yield(.batch(fresh))
                    cursor = max(cursor, fresh.map(\.timestamp).max() ?? cursor)
                }
            } catch let error as GcloudCLI.CLIError {
                // Auth/permission errors won't fix themselves — surface and stop.
                cont.yield(.error(error))
                if case .notAuthenticated = error { break }
                if case .noPermission = error { break }
            } catch {
                // Transient (network blip) — keep polling.
            }
        }
        cont.finish()
    }
}
