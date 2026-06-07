import Foundation

/// A tab in the workspace. Both log sessions and network-inspection sessions
/// conform, so the tab strip and detail area host them uniformly.
@MainActor
protocol WorkspaceTab: AnyObject, Identifiable {
    var id: UUID { get }
    var displayName: String { get set }
    var subtitle: String { get }
    var isRunning: Bool { get }
    var device: Device { get }
    func stop()
}
