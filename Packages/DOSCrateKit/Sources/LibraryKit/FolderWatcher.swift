import CoreServices
import Foundation

/// Watches a folder tree with FSEvents and calls `onChange` (on a private queue) when a relevant path changes.
public final class FolderWatcher: @unchecked Sendable {
    private final class Box {
        let isRelevant: @Sendable (String) -> Bool
        let onChange: @Sendable () -> Void
        init(_ isRelevant: @escaping @Sendable (String) -> Bool, _ onChange: @escaping @Sendable () -> Void) {
            self.isRelevant = isRelevant
            self.onChange = onChange
        }
    }

    private let queue = DispatchQueue(label: "com.songer522.DOSCrate.FolderWatcher")
    private var stream: FSEventStreamRef?
    private var box: Unmanaged<Box>?

    public init(url: URL, isRelevant: @escaping @Sendable (String) -> Bool = { _ in true },
                onChange: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(Box(isRelevant, onChange))
        self.box = box
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            if paths.isEmpty || paths.contains(where: box.isRelevant) { box.onChange() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags)
        else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
        // Let a callback already running on the queue finish before its box goes away.
        queue.sync {}
        box?.release()
    }
}
