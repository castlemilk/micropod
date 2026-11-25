import Darwin
import Foundation
import MicropodCore

// MARK: - Locks

/// An exclusive `flock(2)` on a file, held until `release()` or process
/// exit. The descriptor is close-on-exec, so a spawned VMM never inherits
/// (and outlives the supervisor holding) the lock.
final class HVFFileLock: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    /// The lock, or nil when another process still holds it after `wait`.
    /// Readers probe with a brief shared lock, so a single failed attempt
    /// does not prove another owner.
    static func acquire(_ url: URL, wait: Duration) throws -> HVFFileLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HVFFiles.posixError("open \(url.path)") }
        let deadline = ContinuousClock.now + wait
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return HVFFileLock(fd: fd) }
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                close(fd)
                throw HVFFiles.posixError("flock \(url.path)", code)
            }
            if ContinuousClock.now >= deadline {
                close(fd)
                return nil
            }
            usleep(10_000)
        }
    }

    /// Records `pid` in the lock file for humans (`cat run/supervisor.lock`).
    func record(pid: Int32) throws {
        try lock.withLock {
            guard fd >= 0, ftruncate(fd, 0) == 0 else { throw HVFFiles.posixError("truncate lock") }
            let text = "\(pid)\n"
            guard pwrite(fd, text, text.utf8.count, 0) == text.utf8.count else {
                throw HVFFiles.posixError("write lock")
            }
        }
    }

    func release() {
        lock.withLock {
            guard fd >= 0 else { return }
            close(fd)
            fd = -1
        }
    }

    deinit { release() }

    /// The pid a holder recorded with `record(pid:)`, if any.
    static func recordedPID(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True when some process holds an exclusive lock on `url`.
    static func isHeld(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        while true {
            if flock(fd, LOCK_SH | LOCK_NB) == 0 {
                flock(fd, LOCK_UN)
                return false
            }
            if errno == EINTR { continue }
            return errno == EWOULDBLOCK
        }
    }
}

// MARK: - Process facts

/// What the kernel reports about a process, used to prove a pid is this
/// root's micropod-vmm (or supervisor) before signalling it.
public struct HVFProcessFacts: Sendable, Equatable {
    public var pid: Int32
    public var executablePath: String?
    public var arguments: [String]
    public var startSeconds: Int64?

    public init(pid: Int32, executablePath: String?, arguments: [String], startSeconds: Int64?) {
        self.pid = pid
        self.executablePath = executablePath
        self.arguments = arguments
        self.startSeconds = startSeconds
    }
}

public protocol HVFProcessInspecting: Sendable {
    /// nil when no such process exists (or it is not inspectable).
    func facts(_ pid: Int32) -> HVFProcessFacts?
    /// This user's processes whose executable is exactly `path` (canonical).
    func processes(executable path: String) -> [Int32]
    func isAlive(_ pid: Int32) -> Bool
    /// `kill(2)`: nil on success, else why it failed.
    func signal(_ pid: Int32, _ signal: Int32) -> String?
}

public struct HVFDarwinProcessInspector: HVFProcessInspecting {
    public init() {}

    public func facts(_ pid: Int32) -> HVFProcessFacts? {
        guard pid > 0, isAlive(pid) else { return nil }
        let start = (try? RuntimeProcessBirth.read(pid)).flatMap { $0 }?.seconds
        return HVFProcessFacts(
            pid: pid, executablePath: Self.executablePath(pid), arguments: Self.arguments(pid) ?? [],
            startSeconds: start)
    }

    public func processes(executable path: String) -> [Int32] {
        let capacity = 16384
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), &pids, Int32(capacity * 4))
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / 4).filter { pid in
            pid > 0 && Self.executablePath(pid).map(HVFMachineLayout.canonicalPath) == path
        }
    }

    public func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public func signal(_ pid: Int32, _ signal: Int32) -> String? {
        guard pid > 1 else { return "refusing to signal pid \(pid)" }
        return kill(pid, signal) == 0 ? nil : String(cString: strerror(errno))
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// argv from `KERN_PROCARGS2`: argc, the exec path, padding, then argv.
    static func arguments(_ pid: Int32) -> [String]? {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        size = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }  // exec path
        while index < size, buffer[index] == 0 { index += 1 }  // padding
        var out: [String] = []
        while out.count < Int(argc), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            out.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return out
    }
}

// MARK: - Bounded logs

/// An append-only log file capped at `maxBytes`: when a write would cross
/// the cap the file moves to `<name>.1` (replacing the previous one) and a
/// fresh file starts, so at most two caps of output are kept.
final class HVFRotatingLog: @unchecked Sendable {
    private let lock = NSLock()
    let url: URL
    let maxBytes: Int
    private var fd: Int32 = -1
    private var size = 0

    init(url: URL, maxBytes: Int) throws {
        self.url = url
        self.maxBytes = maxBytes
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lock.withLock { try openLocked() }
    }

    deinit { close() }

    private func openLocked() throws {
        fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw HVFFiles.posixError("open \(url.path)") }
        var info = stat()
        size = fstat(fd, &info) == 0 ? Int(info.st_size) : 0
    }

    func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try lock.withLock {
            guard fd >= 0 else { return }
            if size > 0, size + data.count > maxBytes {
                Darwin.close(fd)
                fd = -1
                let rotated = url.path + ".1"
                if rename(url.path, rotated) != 0 { throw HVFFiles.posixError("rotate \(url.path)") }
                try openLocked()
            }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw HVFFiles.posixError("write \(url.path)") }
                    offset += n
                }
            }
            size += data.count
        }
    }

    func close() {
        lock.withLock {
            guard fd >= 0 else { return }
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Rotates `url` before a writer that cannot rotate (an inherited
    /// descriptor) appends to it.
    static func rotateIfLarger(_ url: URL, than maxBytes: Int) throws {
        var info = stat()
        guard stat(url.path, &info) == 0, Int(info.st_size) > maxBytes else { return }
        if rename(url.path, url.path + ".1") != 0 { throw HVFFiles.posixError("rotate \(url.path)") }
    }
}

// MARK: - Spawning

enum HVFSpawn {
    /// Wait-status decoding (`WIFEXITED` and friends are macros Swift does
    /// not import).
    static func describe(status: Int32) -> (code: Int32?, signal: Int32?) {
        let low = status & 0x7f
        if low == 0 { return ((status >> 8) & 0xff, nil) }
        return (nil, low)
    }

    /// `posix_spawn` with stdin from /dev/null and stdout+stderr on `output`.
    /// Close-on-exec by default: the child inherits nothing else.
    /// `newSession` detaches it from the caller's terminal and process
    /// group, and starts it in `/` so a long-lived daemon never pins the
    /// caller's working directory (and its volume) — every path the
    /// supervisor and the VMM use is absolute. Otherwise it gets a process
    /// group of its own so a terminal's Ctrl-C reaches only the parent,
    /// which forwards one deliberate signal.
    static func spawn(
        executable: String, arguments: [String], environment: [String: String], output: Int32, newSession: Bool
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, output, 2)
        if newSession { posix_spawn_file_actions_addchdir_np(&actions, "/") }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = Int32(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        if newSession {
            flags |= Int32(POSIX_SPAWN_SETSID)
        } else {
            flags |= Int32(POSIX_SPAWN_SETPGROUP)
            posix_spawnattr_setpgroup(&attributes, 0)
        }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard rc == 0 else { throw HVFFiles.posixError("spawn \(executable)", rc) }
        return pid
    }
}
