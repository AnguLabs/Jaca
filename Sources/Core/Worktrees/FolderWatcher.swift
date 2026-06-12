import Foundation

/// Watches a directory for top-level changes (e.g. worktrees added/removed) via a
/// DispatchSource on its file descriptor, calling `onChange` on the main queue, debounced.
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject
    private var debounce: DispatchWorkItem?

    init?(url: URL, debounceSeconds: Double = 1.5, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            let work = DispatchWorkItem(block: onChange)
            self?.debounce?.cancel()
            self?.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + debounceSeconds, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    func cancel() {
        debounce?.cancel()
        source.cancel()
    }

    deinit { cancel() }
}
