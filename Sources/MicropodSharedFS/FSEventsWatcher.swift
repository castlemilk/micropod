import CoreServices
import Foundation

/// Watches a source tree for changes via FSEvents. Each significant change
/// invalidates the per-view caches; the daemon re-clones only files that
/// actually changed on the next access. macOS-only — `FSEventStream`
/// doesn't exist on other platforms (the daemon's platform guard is at the
/// top-level entry point).
public final class FSEventsWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void
    private let contextPointer: UnsafeMutablePointer<FSEventStreamContext>

    public init(path: URL, latency: CFTimeInterval = 0.1, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let holder = Unmanaged.passRetained(ContextHolder(callback: onChange))
        var context = FSEventStreamContext(
            version: 0,
            info: holder.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        self.contextPointer = withUnsafeMutablePointer(to: &context) { $0 }
        let paths = [path.path] as CFArray
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, count, _, _, _ in
            guard let info, count > 0 else { return }
            let holder = Unmanaged<ContextHolder>.fromOpaque(info).takeUnretainedValue()
            holder.callback()
        }
        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            contextPointer,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags)!
        self.stream = stream
        self.contextHolder = holder
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
    }

    private let contextHolder: Unmanaged<ContextHolder>

    private final class ContextHolder {
        let callback: @Sendable () -> Void
        init(callback: @escaping @Sendable () -> Void) { self.callback = callback }
    }

    public func start() {
        guard let stream else { return }
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        contextHolder.release()
    }

    deinit { stop() }
}
