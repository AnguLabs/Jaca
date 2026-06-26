import Foundation

/// A tab in the workspace. Device log sessions, network-inspection sessions, and
/// Cloud Logging sessions all conform, so the tab strip and detail area host them
/// uniformly. (No `device` requirement — a Cloud Logging session isn't bound to a
/// device; the concrete device-backed sessions keep their own `device` property.)
@MainActor
protocol WorkspaceTab: AnyObject, Identifiable {
    var id: UUID { get }
    var displayName: String { get set }
    var subtitle: String { get }
    var isRunning: Bool { get }
    func stop()
}
