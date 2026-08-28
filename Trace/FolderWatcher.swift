import Foundation

/// Watches one directory for entries appearing or disappearing.
///
/// Deliberately not FSEvents. An FSEvents stream on a Dropbox root reports every
/// file change anywhere beneath it, which on a synced team folder is a constant
/// drip of wake-ups for events this app doesn't care about — the opposite of
/// what you want in a menu bar app that's meant to cost nothing while idle. A
/// vnode source on the directory's own descriptor fires only when *that*
/// directory's list of entries changes, which is precisely what turning
/// selective sync on and off does. One file descriptor, no polling, no timer.
@MainActor
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private(set) var watchedPath: String?

    /// Starts watching `path`, calling `onChange` on the main queue. Re-calling
    /// with the same path is a no-op, so it's safe to call on every refresh.
    func start(path: String, onChange: @escaping @MainActor () -> Void) {
        guard path != watchedPath else { return }
        stop()
        guard !path.isEmpty else { return }

        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // The kernel reports several events for one user action, and Dropbox
            // rewrites a folder rather than moving it. Coalesce.
            self?.pending?.cancel()
            let work = DispatchWorkItem { MainActor.assumeIsolated { onChange() } }
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
        source.setCancelHandler { close(descriptor) }

        self.source = source
        watchedPath = path
        source.resume()
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        watchedPath = nil
    }
}
