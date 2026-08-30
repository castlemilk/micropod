import Foundation

/// An advisory, cross-process exclusive lock for one volume's sync.
///
/// Apple's runtime attaches a block volume to a single running VM, so two
/// materializations into the same volume cannot overlap: the second helper
/// fails to bootstrap with "The storage device attachment is invalid", and the
/// loser may already have shipped a partial tar. Two CI jobs sharing a cache
/// volume is not hypothetical — a Cuttlefish agent with capacity > 1 will do
/// exactly that.
///
/// `flock` rather than a lockfile-with-pid: the kernel releases it if the
/// holder dies, so a crashed sync cannot wedge the volume forever.
public final class VolumeSyncLock: @unchecked Sendable {
    private let descriptor: Int32
    public let path: URL

    public enum Failure: Error, CustomStringConvertible {
        case busy(volume: String)
        case unopenable(path: String, errno: Int32)

        public var description: String {
            switch self {
            case .busy(let volume):
                return
                    "another sync is already running for volume '\(volume)' "
                    + "(block volumes admit one writer at a time)"
            case .unopenable(let path, let code):
                return "could not open lock file \(path): errno \(code)"
            }
        }
    }

    /// Takes the lock, waiting up to `timeout` for a concurrent sync to finish.
    ///
    /// Waiting rather than failing immediately: back-to-back CI jobs contending
    /// for one cache volume is the expected case, and a short queue is far
    /// better than a failed build.
    public init(root: URL, volume: String, timeout: Duration = .seconds(120)) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Hash the name: a volume name may contain characters that are not
        // safe as a path component.
        let key = (try? ChunkHash.compute(Data(volume.utf8)))?.value ?? "unkeyed"
        let lockPath = root.appendingPathComponent("\(key).lock")
        self.path = lockPath

        let fd = open(lockPath.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw Failure.unopenable(path: lockPath.path, errno: errno)
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        var acquired = false
        while !acquired {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                acquired = true
                break
            }
            if ContinuousClock.now >= deadline {
                close(fd)
                throw Failure.busy(volume: volume)
            }
            // No flock-with-timeout on Darwin; poll rather than block forever
            // in LOCK_EX, which would ignore the deadline entirely.
            usleep(100_000)
        }
        self.descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
