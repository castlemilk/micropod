import Containerization
import Darwin
import Foundation
import MicropodCore
import Virtualization

/// One persistent Linux kernel and ext4 disk per trusted runner account.
public struct CIWorker: Sendable {
    enum Engine: String {
        case containerd, docker

        var image: String {
            switch self {
            case .containerd:
                return
                    "docker.io/library/alpine:3.23@sha256:469c9ea410b9215eaee7976ba6c0639039b444be8e5d638f7abbada189971eb2"
            case .docker: return CIWorker.dockerImage
            }
        }
    }

    static let apiVersion = "v1.47"
    static let dockerImage =
        "docker.io/library/docker:29.9.3-dind@sha256:7bf70dcb85c822e3fa6f2d332143e474b99147b9d7b39102b0cfe8b04a7dd61b"
    static let guestSocket = "/var/lib/micropod/docker.sock"
    public let directory: URL
    let resourceEnvironment: [String: String]
    public var isNativeRunner: Bool { resourceEnvironment["MICROPOD_CI_ENGINE"] == "containerd" }
    public var socket: URL { directory.appendingPathComponent(isNativeRunner ? "oci.sock" : "docker.sock") }
    var portSocket: URL { directory.appendingPathComponent("ports.sock") }
    var dockerSocket: URL { directory.appendingPathComponent("docker.sock") }
    var ociSocket: URL { directory.appendingPathComponent("oci.sock") }
    static let guestOCI = "/var/lib/micropod/oci.sock"
    public var endpoint: String { "unix://" + socket.path }
    var disk: URL { directory.appendingPathComponent("worker.ext4") }
    var log: URL { directory.appendingPathComponent("worker.log") }
    private var manifest: URL { directory.appendingPathComponent("worker.json") }
    private var session: URL { directory.appendingPathComponent("session.json") }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let resourceKeys = [
            "MICROPOD_CI_CPUS", "MICROPOD_CI_MEMORY_MIB", "MICROPOD_CI_DISK_GIB", "MICROPOD_CI_WORKSPACE",
            "MICROPOD_CI_EXT4_MAX_BATCH_US", "MICROPOD_CI_OCI_TOOLS", "MICROPOD_CI_ENGINE", "MICROPOD_CI_KATA_TOOLS",
        ]
        resourceEnvironment = environment.filter { resourceKeys.contains($0.key) }
        directory =
            environment["MICROPOD_CI_HOME"].map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                environment["MICROPOD_CI_ENGINE"] == "containerd" ? ".micropod/runner" : ".micropod/ci")
    }

    struct Configuration: Codable, Equatable {
        let schema: Int
        let image: String
        let worker: UUID
        let cpus: Int
        let memoryMiB: Int
        let diskGiB: Int
        let workspace: String?
        let ext4MaxBatchUS: Int?
        let kataTools: String?

        var engine: Engine { image == CIWorker.dockerImage ? .docker : .containerd }
    }

    struct Session: Codable, Equatable {
        let owner: RuntimeProcessBirth
        let instance: UUID
        var guestAddress: String?
        var started = false
        var readySocket: ReadySocket?
        var supportsNetworkRepair: Bool?
        var nativeOCI: Bool?
    }

    struct ReadySocket: Codable, Equatable {
        let worker: UUID
        let device: dev_t
        let inode: ino_t

        init?(at url: URL, worker: UUID) {
            var st = stat()
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == getuid() else {
                return nil
            }
            self.worker = worker
            device = st.st_dev
            inode = st.st_ino
        }
    }

    public struct Status: Codable, Sendable {
        public let endpoint: String
        public let worker: UUID
        public let boot: UUID
        public let instance: UUID
        public let engine: String
        public let daemon: String
        public let engineVersion: String
        public let guestAddress: String?
        public let cpus: Int
        public let memoryBytes: UInt64
        public let storageDriver: String
        public var kataPrerequisitesPresent: Bool? = nil
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

    func configuration(create: Bool = false) throws -> Configuration {
        let selection = resourceEnvironment["MICROPOD_CI_ENGINE"] ?? "docker"
        guard let engine = Engine(rawValue: selection) else {
            throw MicropodError.message("MICROPOD_CI_ENGINE must select containerd or docker")
        }
        let fm = FileManager.default
        let existing: Configuration?
        if fm.fileExists(atPath: manifest.path) {
            existing = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: manifest))
            guard existing?.schema == 1, existing?.image == engine.image else {
                throw MicropodError.message(
                    "This CI disk belongs to another engine or schema. Use a fresh MICROPOD_CI_HOME for \(selection). "
                        + "An existing Docker disk can be reopened with MICROPOD_CI_ENGINE=docker.")
            }
        } else {
            guard create, !fm.fileExists(atPath: disk.path) else {
                throw MicropodError.message("Missing CI disk manifest at \(manifest.path)")
            }
            existing = nil
        }
        func resource(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) throws -> Int {
            let raw = resourceEnvironment["MICROPOD_CI_" + key]
            guard let value = Int(raw ?? String(fallback)), range.contains(value) else {
                throw MicropodError.message("MICROPOD_CI_\(key) must be in \(range)")
            }
            return value
        }
        let workspace: String?
        let requested = resourceEnvironment["MICROPOD_CI_WORKSPACE"]
        if let path = requested ?? existing?.workspace, requested != nil || create {
            workspace = try Self.workspacePath(path, excluding: directory)
        } else {
            workspace = existing?.workspace
        }
        let batchUS = try resource("EXT4_MAX_BATCH_US", existing?.ext4MaxBatchUS ?? 15000, 0...Int(Int32.max))
        let config = try Configuration(
            schema: 1, image: engine.image, worker: existing?.worker ?? UUID(),
            cpus: resource("CPUS", existing?.cpus ?? 4, 1...64),
            memoryMiB: resource("MEMORY_MIB", existing?.memoryMiB ?? 4096, 1024...262144),
            diskGiB: resource("DISK_GIB", existing?.diskGiB ?? 32, 4...1024), workspace: workspace,
            ext4MaxBatchUS: batchUS == 15000 ? nil : batchUS,
            kataTools: resourceEnvironment["MICROPOD_CI_KATA_TOOLS"] ?? existing?.kataTools)
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

    static func workspacePath(_ raw: String, excluding state: URL? = nil) throws -> String {
        let fm = FileManager.default
        guard raw.hasPrefix("/"), let resolved = realpath(raw, nil) else {
            throw MicropodError.message("CI workspace must be an existing absolute directory")
        }
        defer { free(resolved) }
        let path = String(cString: resolved)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
            ["/Users/", "/Volumes/", "/private/tmp/"].contains(where: { path.hasPrefix($0) })
        else {
            throw MicropodError.message(
                "CI workspace must be an existing absolute directory under /Users, /Volumes or /private/tmp")
        }
        if let state {
            guard let resolvedState = realpath(state.path, nil) else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            defer { free(resolvedState) }
            let statePath = String(cString: resolvedState)
            guard path != statePath, !path.hasPrefix(statePath + "/"), !statePath.hasPrefix(path + "/") else {
                throw MicropodError.message("The shared checkout and the worker disk directory must be separate")
            }
        }
        return path
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
            // This disk outlives its supervisor. Replay the ext4 journal after an abrupt host or VM exit.
            _ = try await EXT4Unpacker(capacityInBytes: bytes, journal: .init(defaultMode: .ordered))
                .unpack(image, for: .current, at: partial)
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
        if [ -S /var/lib/micropod/docker.sock ]; then rm /var/lib/micropod/docker.sock; fi
        ln -sf /var/lib/micropod/docker.sock /var/run/docker.sock
        if [ "${MICROPOD_NATIVE_OCI:-0}" = 1 ]; then
            /opt/micropod-oci/service serve &
        fi
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
        let Labels: [String]?
        let CgroupVersion: String
        let NCPU: Int
        let MemTotal: UInt64
        let Driver: String
        let CgroupDriver: String
    }

    private var client: DockerClient { DockerClient(endpoint: .unix(socket.path), version: Self.apiVersion) }

    public func status() async throws -> Status {
        guard FileManager.default.fileExists(atPath: session.path) else {
            throw MicropodError.message("CI worker is stopped")
        }
        try prepareDirectory()
        guard let active = try liveSession() else { throw MicropodError.message("CI worker is stopped") }
        guard active.started else { throw MicropodError.message("CI worker is booting") }
        return try await inspectEngine(active, config: configuration())
    }

    private func inspectEngine(_ active: Session, config: Configuration) async throws -> Status {
        if config.engine == .containerd {
            struct Identity: Decodable {
                let worker: UUID
                let instance: UUID
                let boot: UUID
                let engine: String
                let version: String
                let memory_bytes: UInt64
                let kata_prerequisites_present: Bool?
            }
            let identity = try await JSONDecoder().decode(Identity.self, from: nativeControl("/runner"))
            guard identity.worker == config.worker, identity.instance == active.instance,
                identity.engine == "containerd"
            else { throw MicropodError.message("The native endpoint did not identify the active runner") }
            return Status(
                endpoint: endpoint, worker: config.worker, boot: identity.boot, instance: active.instance,
                engine: "containerd", daemon: identity.engine, engineVersion: identity.version,
                guestAddress: active.guestAddress, cpus: config.cpus, memoryBytes: identity.memory_bytes,
                storageDriver: "overlayfs", kataPrerequisitesPresent: identity.kata_prerequisites_present,
                cgroupDriver: "cgroupfs")
        }
        let response = try await client.request("GET", "/info", timeout: .seconds(2))
        guard response.status == 200 else { throw MicropodError.message("CI engine: \(response.message)") }
        let info = try JSONDecoder().decode(Info.self, from: response.body)
        let boot: UUID
        do {
            let labels = info.Labels ?? []
            let boots = labels.compactMap { label -> UUID? in
                let prefix = "io.micropod.ci.boot="
                return label.hasPrefix(prefix) ? UUID(uuidString: String(label.dropFirst(prefix.count))) : nil
            }
            guard info.CgroupVersion == "2", info.CgroupDriver == "cgroupfs", !info.ID.isEmpty,
                labels.contains("io.micropod.ci.worker=" + config.worker.uuidString),
                labels.contains("io.micropod.ci.instance=" + active.instance.uuidString), boots.count == 1
            else { throw MicropodError.message("Docker endpoint did not identify the active Micropod CI worker") }
            boot = boots[0]
        }
        return Status(
            endpoint: endpoint, worker: config.worker, boot: boot, instance: active.instance,
            engine: config.engine.rawValue,
            daemon: info.ID, engineVersion: info.ServerVersion, guestAddress: active.guestAddress, cpus: info.NCPU,
            memoryBytes: info.MemTotal, storageDriver: info.Driver,
            cgroupDriver: info.CgroupDriver)
    }

    static func hostname(_ instance: UUID) -> String { "mp-" + instance.uuidString.lowercased() }

    /// The client checks liveness when it submits the job. Its endpoint is attested once per boot.
    public func runEndpoint(executable: URL) async throws -> String {
        try prepareDirectory()
        if let active = try? liveSession(), active.started, let verified = active.readySocket,
            !FileManager.default.fileExists(atPath: stopFile(active).path),
            ReadySocket(at: socket, worker: try configuration().worker) == verified
        {
            return endpoint
        }
        return try await start(executable: executable).endpoint
    }

    /// Verify that the API on the second socket belongs to the running native worker.
    public func nativeDockerEndpoint(executable: URL) async throws -> String {
        let active = try await start(executable: executable)
        let api = DockerClient(endpoint: .unix(dockerSocket.path), version: Self.apiVersion)
        let reply = try await api.request("GET", "/info", timeout: .seconds(3))
        guard reply.status == 200, let info = try reply.json() as? [String: Any],
            info["ID"] as? String == active.worker.uuidString,
            (info["Labels"] as? [String])?.contains("io.micropod.instance=" + active.instance.uuidString) == true
        else { throw MicropodError.message("Native Docker API did not identify the active worker") }
        return "unix://" + dockerSocket.path
    }

    public func start(executable: URL) async throws -> Status {
        try prepareDirectory()
        if FileManager.default.fileExists(atPath: manifest.path) { _ = try configuration() }
        let deadline = ContinuousClock.now + .seconds(180)
        var election: FileHandle?
        var child: Process?
        var launchdDeadline: ContinuousClock.Instant?
        var sawSupervisor = false
        defer { try? election?.close() }
        repeat {
            if let active = try? liveSession() {
                guard !FileManager.default.fileExists(atPath: stopFile(active).path) else {
                    throw MicropodError.message("CI worker is stopping")
                }
                sawSupervisor = true
                if active.started, let current = try? await inspectEngine(active, config: configuration()) {
                    return current
                }
            } else if sawSupervisor {
                throw MicropodError.message("CI worker startup failed; see \(log.path)")
            } else if let child, !child.isRunning {
                let delivered = child.terminationStatus == 0 && launchdDeadline.map { .now < $0 || isOwned() } == true
                let joined = child.terminationStatus == Self.alreadyOwned && isOwned()
                guard delivered || joined else {
                    throw MicropodError.message("CI worker startup failed; see \(log.path)")
                }
            } else if election == nil, let lock = try acquire("start.lock") {
                election = lock
                if (try? liveSession()) == nil {
                    let service = try serviceTarget()
                    child = try launchSupervisor(executable: executable, service: service)
                    if service != nil { launchdDeadline = .now + .seconds(15) }
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        throw MicropodError.message("Timed out waiting for the CI engine; see \(log.path)")
    }

    private func launchSupervisor(executable: URL, service: String?) throws -> Process {
        let process = Process()
        if let service {
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", service]
        } else {
            process.executableURL = executable
            process.arguments = ["ci", "serve"]
            var env = ProcessInfo.processInfo.environment
            env.merge(resourceEnvironment) { _, selected in selected }
            env["MICROPOD_CI_HOME"] = directory.path
            process.environment = env
        }
        let fd = open(log.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    public static let alreadyOwned: Int32 = 75

    // An open-file-description lock survives request cancellation, but releases on supervisor death.
    private func acquire(_ name: String = "worker.lock") throws -> FileHandle? {
        let fd = open(
            directory.appendingPathComponent(name).path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return handle }
        let reason = errno
        try handle.close()
        if reason == EWOULDBLOCK { return nil }
        throw POSIXError(.init(rawValue: reason) ?? .EIO)
    }

    func isOwned() -> Bool {
        do {
            guard let handle = try acquire() else { return true }
            try handle.close()
        } catch { return true }
        return false
    }

    private func stopFile(_ value: Session) -> URL {
        directory.appendingPathComponent("stop-" + value.instance.uuidString)
    }

    private func networkRequest(_ active: Session) -> URL {
        directory.appendingPathComponent("network-repair-" + active.instance.uuidString)
    }

    public func repairNetwork() async throws -> NetworkRepair {
        try prepareDirectory()
        guard let active = try liveSession(), active.started, active.supportsNetworkRepair == true else {
            throw MicropodError.message("Network recovery needs a running worker with live repair support")
        }
        guard let lock = try acquire("network-request.lock") else {
            throw MicropodError.message("A network repair request is already pending")
        }
        defer { try? lock.close() }
        let token = UUID()
        let file = networkRequest(active)
        try JSONEncoder().encode(token).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let receipt = directory.appendingPathComponent("network.json")
        let deadline = ContinuousClock.now + .seconds(45)
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: receipt),
                let value = try? JSONDecoder().decode(NetworkRepair.self, from: data),
                value.request == token, value.instance == active.instance
            {
                if let error = value.error { throw MicropodError.message(error) }
                return value
            }
            if try active.owner.hasExited() { throw MicropodError.message("CI worker exited during network repair") }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MicropodError.message("Timed out waiting for CI network repair")
    }

    @discardableResult
    func nativeControl(_ path: String, method: String = "GET") async throws -> Data {
        let api = DockerClient(endpoint: .unix(ociSocket.path), version: "oci/v1")
        let reply = try await api.request(method, path, timeout: .seconds(3))
        guard reply.status == 200 else { throw MicropodError.message("Native OCI service: \(reply.message)") }
        return reply.body
    }

    public func kernelMetrics() async throws -> KernelMetrics {
        guard try liveSession()?.nativeOCI == true else {
            throw MicropodError.message("Kernel metrics require a running native CI worker")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try await decoder.decode(KernelMetrics.self, from: nativeControl("/kernel"))
    }

    func nativeMetrics() async throws -> NativeOCIMetrics? {
        guard try liveSession()?.nativeOCI == true else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try await decoder.decode(NativeOCIMetrics.self, from: nativeControl("/status"))
    }

    /// All guest executables come from a dedicated read-only tools share.
    func nativeTools(engine: Engine) throws -> URL? {
        let dir: URL
        if let explicit = resourceEnvironment["MICROPOD_CI_OCI_TOOLS"] {
            dir = URL(fileURLWithPath: explicit)
        } else {
            guard let bin = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() else {
                return nil
            }
            var candidates = [bin.appendingPathComponent("micropod-oci-tools")]
            if bin.lastPathComponent == "MacOS" {
                candidates.append(
                    bin.deletingLastPathComponent().appendingPathComponent("Resources/micropod-oci-tools"))
            }
            let build = bin.deletingLastPathComponent().deletingLastPathComponent()
            if build.lastPathComponent == ".build" {
                candidates.append(build.appendingPathComponent("oci-tools/guest"))
            }
            guard let installed = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                return nil
            }
            dir = installed
        }
        var tools = ["service", "executor"]
        if engine == .containerd {
            tools += [
                "crun-1.31-arm64", "runner/bin/containerd", "runner/bin/containerd-shim-runc-v2", "runner/bin/job",
            ]
            guard FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("runner/start.sh").path)
            else { throw MicropodError.message("Build the containerd runner tools with ci/build-runner-tools.sh") }
        }
        for name in tools {
            let f = dir.appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: f.path),
                let file = try? FileHandle(forReadingFrom: f)
            else { throw MicropodError.message("Missing native OCI guest tool: \(f.path)") }
            defer { try? file.close() }
            guard let header = try file.read(upToCount: 20), header.count == 20,
                header.starts(with: [0x7f, 0x45, 0x4c, 0x46, 2, 1]), header[18] == 183, header[19] == 0
            else { throw MicropodError.message("Expected a Linux ARM64 executable at \(f.path)") }
        }
        return dir.standardizedFileURL
    }

    private func checkIdle(using endpoint: URL) async throws {
        let api = DockerClient(endpoint: .unix(endpoint.path), version: Self.apiVersion)
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
            if !isNativeRunner { try await checkIdle(using: socket) }
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
        if isNativeRunner {
            do {
                try await nativeControl("/drain", method: "POST")
                return true
            } catch {
                try FileManager.default.removeItem(at: stopFile(active))
                return false
            }
        }
        let paused = directory.appendingPathComponent("idle.sock")
        guard rename(socket.path, paused.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        do {
            try await checkIdle(using: paused)
            if active.nativeOCI == true { try await nativeControl("/drain", method: "POST") }
        } catch {
            guard rename(paused.path, socket.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            try FileManager.default.removeItem(at: stopFile(active))
            return false
        }
        try FileManager.default.removeItem(at: paused)
        return true
    }

    private enum Event: Sendable {
        case maintenance, checkNetwork, terminate, timedOut
        case exited(String)
    }

    public func serve() async throws -> Int32 {
        try prepareDirectory()
        guard let lock = try acquire() else { return Self.alreadyOwned }
        defer { try? lock.close() }
        // A client may close an attached stream while the vsock relay still has bytes to send.
        // Deliver EPIPE to that connection; the worker must keep serving the other jobs.
        signal(SIGPIPE, SIG_IGN)
        guard VZVirtualMachine.isSupported else {
            throw MicropodError.message("Apple Virtualization is unavailable on this Mac")
        }
        let config = try configuration(create: true)
        guard let owner = try RuntimeProcessBirth.read(getpid()) else {
            throw MicropodError.message("Missing supervisor identity")
        }
        var active = Session(owner: owner, instance: UUID(), supportsNetworkRepair: true)
        try JSONEncoder().encode(active).write(to: session, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: session)
            try? FileManager.default.removeItem(at: stopFile(active))
            try? FileManager.default.removeItem(at: networkRequest(active))
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

        var options = SandboxVM.Options(base: .image(config.image))
        options.network = true
        options.hostname = config.engine == .containerd ? Self.hostname(active.instance) : "micropod-ci"
        options.ciWorkspace = config.workspace
        if let path = config.kataTools {
            guard config.engine == .containerd, VZGenericPlatformConfiguration.isNestedVirtualizationSupported,
                FileManager.default.isExecutableFile(atPath: path + "/bin/containerd-shim-kata-v2")
            else {
                throw MicropodError.message(
                    "Kata requires its Linux ARM64 tools and a nested-virtualization-capable Mac")
            }
            options.ciKataTools = URL(fileURLWithPath: path).standardizedFileURL
        }
        options.ciOCITools = try nativeTools(engine: config.engine)
        if config.engine == .containerd, options.ciOCITools == nil {
            throw MicropodError.message(
                "Containerd runner tools are missing. Build or install ci/build-runner-tools.sh first.")
        }
        active.nativeOCI = options.ciOCITools != nil
        options.ciExt4MaxBatchUS = config.ext4MaxBatchUS
        options.cpus = config.cpus
        options.memoryMiB = UInt64(config.memoryMiB)
        options.diskBytes = UInt64(config.diskGiB) << 30
        options.env = [
            "MICROPOD_CI_WORKER_ID=" + config.worker.uuidString, "MICROPOD_CI_INSTANCE=" + active.instance.uuidString,
        ]
        if active.nativeOCI == true { options.env.append("MICROPOD_NATIVE_OCI=1") }
        if config.engine == .containerd {
            options.env.append("MICROPOD_ENGINE_API=1")
            if let workspace = config.workspace { options.env.append("MICROPOD_ENGINE_WORKSPACE=" + workspace) }
        }
        options.entrypoint = ["/bin/sh", "-c"]
        options.arguments = [config.engine == .containerd ? "exec /opt/micropod-oci/runner/start.sh" : Self.bootstrap]

        let prepared = try await SandboxVM.prepare(
            options, id: "ci-" + active.instance.uuidString.lowercased(), runDir: directory,
            stdout: FileHandleWriter(.standardOutput), stderr: FileHandleWriter(.standardError),
            progress: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }, ciWorker: self)
        do {
            if config.engine == .containerd, let guest = prepared.guestIP {
                try await prepared.forwarding.openNativePortBroker(at: portSocket, guest: guest)
            }
            try await prepared.container.create()
            guard chmod(socket.path, 0o600) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            if chmod(dockerSocket.path, 0o600) != 0 || active.nativeOCI == true && chmod(ociSocket.path, 0o600) != 0 {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            try await prepared.container.start()
            active.guestAddress = prepared.guestIP
            let readyBy = ContinuousClock.now + .seconds(config.engine == .containerd ? 135 : 40)
            while (try? await inspectEngine(active, config: config)) == nil {
                guard ContinuousClock.now < readyBy else {
                    throw MicropodError.message("Guest container engine did not become ready after boot")
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            if active.nativeOCI == true {
                while true {
                    do {
                        try await nativeControl("/status")
                        break
                    } catch {
                        if ContinuousClock.now >= readyBy {
                            throw MicropodError.message("Native OCI guest socket did not become ready: \(error)")
                        }
                        try await Task.sleep(for: .milliseconds(150))
                    }
                }
            }
            active.readySocket = ReadySocket(at: socket, worker: config.worker)
            active.started = true
            try JSONEncoder().encode(active).write(to: session, options: .atomic)
            let wait = Task {
                do {
                    let status = try await prepared.container.wait()
                    stream.yield(.exited("exit \(status.exitCode)"))
                } catch { stream.yield(.exited(error.localizedDescription)) }
            }
            let health = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    stream.yield(.checkNetwork)
                }
            }
            var networkWatch = NetworkWatch()
            var shutdownTimer: Task<Void, Never>?
            defer {
                health.cancel()
                wait.cancel()
                shutdownTimer?.cancel()
            }
            lifecycle: for await event in events {
                switch event {
                case .exited(let reason):
                    guard shutdownTimer != nil else { throw MicropodError.message("CI engine stopped: \(reason)") }
                    break lifecycle
                case .timedOut: throw MicropodError.message("Guest container engine shutdown timed out")
                case .maintenance, .checkNetwork:
                    if shutdownTimer == nil, !FileManager.default.fileExists(atPath: stopFile(active).path),
                        let gateway = prepared.gateway
                    {
                        let requestFile = networkRequest(active)
                        let token = (try? Data(contentsOf: requestFile)).flatMap {
                            try? JSONDecoder().decode(UUID.self, from: $0)
                        }
                        if let receipt = await networkWatch.inspect(
                            prepared, gateway: gateway, instance: active.instance, request: token)
                        {
                            do {
                                try JSONEncoder().encode(receipt).write(
                                    to: directory.appendingPathComponent("network.json"), options: .atomic)
                            } catch {
                                SecretSource.stderrLog(
                                    "Could not record CI network repair: \(error.localizedDescription)")
                            }
                            if token != nil { try? FileManager.default.removeItem(at: requestFile) }
                            SecretSource.stderrLog(
                                "CI network repair (\(receipt.cause ?? "requested")): "
                                    + (receipt.error ?? "gateway restored"))
                        }
                    }
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
