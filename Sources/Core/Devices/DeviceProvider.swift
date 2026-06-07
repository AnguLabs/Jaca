import Foundation

/// A backend that discovers devices for one platform and emits the full current
/// list whenever it changes. The app merges every provider's stream into a single
/// device list, so adding iOS later is just another provider.
protocol DeviceProvider: Sendable {
    var platform: DevicePlatform { get }

    /// Emits the current device list on start and again on every change.
    /// Cancelling the consuming task stops the underlying polling.
    func deviceStream() -> AsyncStream<[Device]>
}
