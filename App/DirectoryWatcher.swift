import Foundation
import CoreServices

/// Fires a debounced callback when anything under a directory tree changes.
///
/// Built on FSEvents rather than a `DispatchSource` vnode watch, because a
/// vnode watch on `~/.claude/projects` never sees ordinary session activity:
/// appending to a transcript bumps neither the transcript's directory mtime nor
/// the tree root's, so the watcher only fired when a brand-new project folder
/// appeared. FSEvents with `kFSEventStreamCreateFlagFileEvents` reports writes
/// to individual files anywhere in the subtree, which is the actual signal.
///
/// Deliberately coarse: this is a *hint* to refresh, and the controller decides
/// whether to act on it.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "ClaudeRunway.watcher")

    init?(url: URL, debounce: TimeInterval, onChange: @escaping () -> Void) {
        self.debounce = debounce
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        // FSEvents does its own coalescing; the latency here is a first pass and
        // `scheduleCallback` debounces what still gets through.
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<DirectoryWatcher>.fromOpaque(info)
                    .takeUnretainedValue()
                    .scheduleCallback()
            },
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce,
            flags
        ) else { return nil }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    private func scheduleCallback() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    deinit {
        pending?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
