import Containerization
import Darwin
import Foundation
import MicropodCore
import Virtualization

/// One Docker engine and writable ext4 disk per trusted macOS runner account.
public struct CIWorker: Sendable {
    static let image =
        "docker.io/library/docker:29.9.3-dind@sha256:7bf70dcb85c822e3fa6f2d332143e474b99147b9d7b39102b0cfe8b04a7dd61b"
    static let guestSocket = "/var/lib/micropod/docker.sock"
    public let directory: URL
    public var socket: URL { directory.appendingPathComponent("docker.sock") }
    public var endpoint: String { "unix://" + socket.path }
    var disk: URL { directory.appendingPathComponent("worker.ext4") }
    var log: URL { directory.appendingPathComponent("worker.log") }
    private var manifest: URL { directory.appendingPathComponent("worker.json") }
    private var session: URL { directory.appendingPathComponent("session.json") }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        directory =
            environment["MICROPOD_CI_HOME"].map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".micropod/ci")
    }

    struct Configuration: Codable, Equatable {
        let schema: Int
        let image: String
        let worker: UUID
        let cpus: Int
        let memoryMiB: Int
        let diskGiB: Int
    }

    struct Session: Codable, Equatable {
        let owner: RuntimeProcessBirth
        let instance: UUID
        var guestAddress: String?
        var started = false
    }

    public struct Status: Codable, Sendable {
        public let endpoint: String
        public let worker: UUID
        public let boot: UUID
        public let instance: UUID
        public let daemon: String
        public let engineVersion: String
        public let guestAddress: String?
        public let cpus: Int
        public let memoryBytes: UInt64
        public let storageDriver: String
        public let cgroupDriver: String
    }

    func prepareDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var st = stat()
        guard lstat(directory.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid(),
            st.st_mode & 0o077 == 0
        else {
            throw MicropodError.message("CI state must be a private directory owned by this account: \(directory.path)")
        }
        guard socket.path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw MicropodError.message("CI socket path is too long: \(socket.path)")
        }
    }

    private func configuration(create: Bool = false) throws -> Configuration {
        let fm = FileManager.default
        let existing: Configuration?
        if fm.fileExists(atPath: manifest.path) {
            existing = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: manifest))
            guard existing?.schema == 1, existing?.image == Self.image else {
                throw MicropodError.message("CI disk belongs to another worker image or storage schema")
            }
        } else {
            guard create, !fm.fileExists(atPath: disk.path) else {
                throw MicropodError.message("Missing CI disk manifest at \(manifest.path)")
            }
            existing = nil
        }
        func resource(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) throws -> Int {
            let raw = ProcessInfo.processInfo.environment["MICROPOD_CI_" + key]
            guard let value = Int(raw ?? String(fallback)), range.contains(value) else {
                throw MicropodError.message("MICROPOD_CI_\(key) must be in \(range)")
            }
            return value
        }
        let config = try Configuration(
            schema: 1, image: Self.image, worker: existing?.worker ?? UUID(),
            cpus: resource("CPUS", existing?.cpus ?? 4, 1...64),
            memoryMiB: resource("MEMORY_MIB", existing?.memoryMiB ?? 4096, 1024...262144),
            diskGiB: resource("DISK_GIB", existing?.diskGiB ?? 32, 4...1024))
        if let existing {
            guard config == existing else {
                throw MicropodError.message(
                    "CI resources differ from \(manifest.path); select a separate worker directory for this configuration"
                )
            }
        } else {
            try JSONEncoder().encode(config).write(to: manifest, options: .atomic)
        }
        return config
    }

    // Called under the supervisor's lifetime lock. Never open an incompletely unpacked image.
    func openDisk(image: Containerization.Image, bytes: UInt64, progress: @Sendable (String) -> Void) async throws
        -> URL
    {
        let fm = FileManager.default
        if !fm.fileExists(atPath: disk.path) {
            let partial = directory.appendingPathComponent("unpacking.ext4")
            if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
            defer { try? fm.removeItem(at: partial) }
            progress("Preparing the CI disk at \(disk.path)")
            _ = try await EXT4Unpacker(capacityInBytes: bytes).unpack(image, for: .current, at: partial)
            try fm.moveItem(at: partial, to: disk)
        }
        var attributes = stat()
        guard lstat(disk.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
            attributes.st_uid == getuid(), attributes.st_nlink == 1
        else {
            throw MicropodError.message("CI worker disk must be an owned regular file with a single link")
        }
        return disk
    }

    static let bootstrap = #"""
        set -eu
        umask 077
        mkdir -p /var/lib/micropod
        ln -sf /var/lib/micropod/docker.sock /var/run/docker.sock
        exec /usr/local/bin/dockerd-entrypoint.sh dockerd \
          --host=unix:///var/lib/micropod/docker.sock --data-root=/var/lib/docker --exec-opt=native.cgroupdriver=cgroupfs \
          --label="io.micropod.ci.worker=$MICROPOD_CI_WORKER_ID" \
          --label="io.micropod.ci.instance=$MICROPOD_CI_INSTANCE" \
          --label="io.micropod.ci.boot=$(cat /proc/sys/kernel/random/boot_id)"
        """#

    private func liveSession() throws -> Session? {
        guard FileManager.default.fileExists(atPath: session.path) else { return nil }
        let value = try JSONDecoder().decode(Session.self, from: Data(contentsOf: session))
        return try value.owner.hasExited() ? nil : value
    }

    private struct Info: Decodable {
        let ID: String
        let ServerVersion: String
        let Labels: [String]
        let CgroupVersion: String
        let NCPU: Int
        let MemTotal: UInt64
        let Driver: String
        let CgroupDriver: String
    }

    private var client: DockerClient { DockerClient(endpoint: .unix(socket.path), version: "v1.47") }

    public func status() async throws -> Status {
        guard FileManager.default.fileExists(atPath: session.path) else {
            throw MicropodError.message("CI worker is stopped")
        }
        try prepareDirectory()
        guard let active = try liveSession() else { throw MicropodError.message("CI worker is stopped") }
        guard active.started else { throw MicropodError.message("CI worker is booting") }
        let config = try configuration()
        let response = try await client.request("GET", "/info", timeout: .seconds(2))
        guard response.status == 200 else { throw MicropodError.message("CI engine: \(response.message)") }
        let info = try JSONDecoder().decode(Info.self, from: response.body)
        let boots = info.Labels.compactMap { label -> UUID? in
            let prefix = "io.micropod.ci.boot="
            return label.hasPrefix(prefix) ? UUID(uuidString: String(label.dropFirst(prefix.count))) : nil
        }
        guard info.Labels.contains("io.micropod.ci.worker=" + config.worker.uuidString),
            info.Labels.contains("io.micropod.ci.instance=" + active.instance.uuidString),
            info.CgroupVersion == "2", info.CgroupDriver == "cgroupfs", !info.ID.isEmpty, boots.count == 1
        else { throw MicropodError.message("Docker endpoint did not identify the active Micropod CI worker") }
        return Status(
            endpoint: endpoint, worker: config.worker, boot: boots[0], instance: active.instance,
            daemon: info.ID, engineVersion: info.ServerVersion, guestAddress: active.guestAddress, cpus: info.NCPU,
            memoryBytes: info.MemTotal, storageDriver: info.Driver,
            cgroupDriver: info.CgroupDriver)
    }

    public func start(executable: URL) async throws -> Status {
        try prepareDirectory()
        if FileManager.default.fileExists(atPath: manifest.path) { _ = try configuration() }
        if let current = try? await status() { return current }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["ci", "serve"]
        let fd = open(log.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now + .seconds(180)
        while ContinuousClock.now < deadline {
            if let current = try? await status() { return current }
            // A concurrent supervisor can win the lock. All starters wait for its actual API.
            if !process.isRunning {
                if process.terminationStatus != Self.alreadyOwned || (try? liveSession()) == nil && !isOwned() {
                    throw MicropodError.message("CI worker startup failed; see \(log.path)")
                }
            }
            try await Task.sleep(for: .milliseconds(125))
        }
        throw MicropodError.message("Timed out waiting for the CI engine; see \(log.path)")
    }

    public static let alreadyOwned: Int32 = 75

    // An open-file-description lock survives request cancellation, but releases on supervisor death.
    private func acquire() throws -> FileHandle? {
        let fd = open(
            directory.appendingPathComponent("worker.lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return handle }
        let reason = errno
        try handle.close()
        if reason == EWOULDBLOCK { return nil }
        throw POSIXError(.init(rawValue: reason) ?? .EIO)
    }

    private func isOwned() -> Bool {
        do {
            guard let handle = try acquire() else { return true }
            try handle.close()
        } catch { return true }
        return false
    }

    private func stopFile(_ value: Session) -> URL {
        directory.appendingPathComponent("stop-" + value.instance.uuidString)
    }

    private func checkIdle(using endpoint: URL) async throws {
        let api = DockerClient(endpoint: .unix(endpoint.path), version: "v1.47")
        let response = try await api.request("GET", "/containers/json", timeout: .seconds(3))
        guard response.status == 200, let jobs = try response.json() as? [[String: Any]], jobs.isEmpty else {
            throw MicropodError.message("Leave the worker running until its active containers finish")
        }
    }

    public func stop() async throws {
        try prepareDirectory()
        guard let active = try liveSession() else {
            if isOwned() { throw MicropodError.message("CI supervisor is starting; retry after it becomes ready") }
            return
        }
        if active.started {
            let current = try await status()
            guard current.instance == active.instance else {
                throw MicropodError.message("CI supervisor changed during stop")
            }
            try await checkIdle(using: socket)
        }
        let request = stopFile(active)
        try Data().write(to: request, options: .atomic)
        defer { try? FileManager.default.removeItem(at: request) }
        let deadline = ContinuousClock.now + .seconds(45)
        while ContinuousClock.now < deadline {
            if try active.owner.hasExited() {
                guard
                    (try? Data(contentsOf: directory.appendingPathComponent("stopped")))
                        == Data(active.instance.uuidString.utf8)
                else {
                    throw MicropodError.message("CI supervisor exited without confirming a clean shutdown")
                }
                return
            }
            if !FileManager.default.fileExists(atPath: request.path), (try? liveSession()) != nil {
                throw MicropodError.message("The CI worker received more work while draining")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MicropodError.message("CI supervisor has not acknowledged shutdown; see \(log.path)")
    }

    // Move the listening socket before checking the active set. Existing connected clients can
    // finish. The scheduler pauses job intake before requesting maintenance, including builds.
    private func drain(_ active: Session) async throws -> Bool {
        let paused = directory.appendingPathComponent("idle.sock")
        guard rename(socket.path, paused.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        do {
            try await checkIdle(using: paused)
        } catch {
            guard rename(paused.path, socket.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            try FileManager.default.removeItem(at: stopFile(active))
            return false
        }
        try FileManager.default.removeItem(at: paused)
        return true
    }

    private enum Event: Sendable {
        case maintenance, terminate, timedOut
        case exited(String)
    }

    public func serve() async throws -> Int32 {
        try prepareDirectory()
        guard let lock = try acquire() else { return Self.alreadyOwned }
        defer { try? lock.close() }
        guard VZVirtualMachine.isSupported else {
            throw MicropodError.message("Apple Virtualization is unavailable on this Mac")
        }
        let config = try configuration(create: true)
        guard let owner = try RuntimeProcessBirth.read(getpid()) else {
            throw MicropodError.message("Missing supervisor identity")
        }
        var active = Session(owner: owner, instance: UUID())
        try JSONEncoder().encode(active).write(to: session, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: session)
            try? FileManager.default.removeItem(at: stopFile(active))
        }

        let (events, stream) = AsyncStream<Event>.makeStream()
        let fd = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let wake = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .global())
        wake.setEventHandler { stream.yield(.maintenance) }
        wake.setCancelHandler { close(fd) }
        wake.resume()
        let signals = [SIGTERM, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { stream.yield(.terminate) }
            source.resume()
            return source
        }
        defer {
            wake.cancel()
            signals.forEach { $0.cancel() }
            stream.finish()
        }

        var options = SandboxVM.Options(base: .image(Self.image))
        options.network = true
        options.hostname = "micropod-ci"
        options.cpus = config.cpus
        options.memoryMiB = UInt64(config.memoryMiB)
        options.diskBytes = UInt64(config.diskGiB) << 30
        options.env = [
            "MICROPOD_CI_WORKER_ID=" + config.worker.uuidString, "MICROPOD_CI_INSTANCE=" + active.instance.uuidString,
        ]
        options.entrypoint = ["/bin/sh", "-c"]
        options.arguments = [Self.bootstrap]

        let prepared = try await SandboxVM.prepare(
            options, id: "ci-" + active.instance.uuidString.lowercased(), runDir: directory,
            stdout: FileHandleWriter(.standardOutput), stderr: FileHandleWriter(.standardError),
            progress: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }, ciWorker: self)
        do {
            try await prepared.container.create()
            guard chmod(socket.path, 0o600) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            try await prepared.container.start()
            active.guestAddress = prepared.guestIP
            active.started = true
            try JSONEncoder().encode(active).write(to: session, options: .atomic)
            let readyBy = ContinuousClock.now + .seconds(40)
            while (try? await status()) == nil {
                guard ContinuousClock.now < readyBy else {
                    throw MicropodError.message("Guest Docker API did not become ready after boot")
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            let wait = Task {
                do {
                    let status = try await prepared.container.wait()
                    stream.yield(.exited("exit \(status.exitCode)"))
                } catch { stream.yield(.exited(error.localizedDescription)) }
            }
            var shutdownTimer: Task<Void, Never>?
            defer {
                wait.cancel()
                shutdownTimer?.cancel()
            }
            lifecycle: for await event in events {
                switch event {
                case .exited(let reason):
                    guard shutdownTimer != nil else { throw MicropodError.message("CI engine stopped: \(reason)") }
                    break lifecycle
                case .timedOut: throw MicropodError.message("Guest Docker shutdown timed out")
                case .maintenance:
                    guard shutdownTimer == nil, FileManager.default.fileExists(atPath: stopFile(active).path),
                        try await drain(active)
                    else { continue }
                case .terminate:
                    if shutdownTimer != nil { continue }
                }
                try await prepared.container.kill(.term)
                shutdownTimer = Task {
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    stream.yield(.timedOut)
                }
            }
        } catch {
            try? await prepared.stop()
            throw error
        }
        try await prepared.stop()
        try Data(active.instance.uuidString.utf8).write(
            to: directory.appendingPathComponent("stopped"), options: .atomic)
        return 0
    }
}
