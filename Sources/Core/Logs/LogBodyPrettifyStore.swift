import Foundation
import Observation

/// App-wide, persisted toggle for auto-prettifying detected JSON response bodies in the
/// log stream (`LogBodyPrettifier`). On by default. The gate is read once per flush, so
/// flipping it off leaves already-prettified lines as they are and simply stops
/// transforming **new** lines — exactly the "next logs won't be prettified" behaviour.
///
/// One owner, many readers (the toolbar chip and every session's flush), per the
/// single-source-of-truth convention — mirrors `LogExclusionStore`.
@MainActor
@Observable
final class LogBodyPrettifyStore {
    static let shared = LogBodyPrettifyStore()

    private static let key = "logPrettifyJSONBodies"

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.key) }
    }

    private init() {
        // Absent key → default ON.
        enabled = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
    }
}
