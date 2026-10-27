import CoreServices
import Foundation

/// Watches a folder tree with FSEvents and calls `onChange` (on a private queue) when anything changes.
public final class FolderWatcher: @unchecked Sendable {
    private final class Box {
        let onChange: @Sendable () -> Void
        init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }

    private let queue = DispatchQueue(label: "com.songer522.DOSCrate.FolderWatcher")
    private var stream: FSEventStreamRef?
    private var box: Unmanaged<Box>?

    public init(url: URL, onChange: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(Box(onChange))
        self.box = box
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().onChange()
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
        box?.release()
    }
}
