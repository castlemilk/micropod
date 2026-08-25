import CoreServices
import Foundation

/// Watches a source tree for changes via FSEvents. Each significant change
/// invalidates the per-view caches; the daemon re-clones only files that
/// actually changed on the next access. macOS-only — `FSEventStream`
/// doesn't exist on other platforms (the daemon's platform guard is at the
/// top-level entry point).
public final class FSEventsWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let contextPtr: UnsafeMutablePointer<FSEventStreamContext>
    private let holder: Unmanaged<ContextHolder>

    public init(
        path: URL, latency: CFTimeInterval = 0.1,
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        let holder = Unmanaged.passRetained(ContextHolder(callback: onChange))
        self.holder = holder
        let ptr = UnsafeMutablePointer<FSEventStreamContext>.allocate(capacity: 1)
        ptr.initialize(
            to: FSEventStreamContext(
                version: 0,
                info: holder.toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil))
        self.contextPtr = ptr
        let paths = [path.path] as CFArray
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let holder = Unmanaged<ContextHolder>.fromOpaque(info).takeUnretainedValue()
            // eventPaths is CFArray of CFString when UseCFTypes is set
            let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
            var changed: [String] = []
            for i in 0..<count {
                if let cfStr = CFArrayGetValueAtIndex(cfArray, i) {
                    let str = unsafeBitCast(cfStr, to: CFString.self) as String
                    changed.append(str)
                }
            }
            if !changed.isEmpty { holder.callback(changed) }
        }
        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            ptr,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags)!
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
    }

    private final class ContextHolder {
        let callback: @Sendable ([String]) -> Void
        init(callback: @escaping @Sendable ([String]) -> Void) { self.callback = callback }
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
        contextPtr.deinitialize(count: 1)
        contextPtr.deallocate()
        holder.release()
    }

    deinit { stop() }
}
