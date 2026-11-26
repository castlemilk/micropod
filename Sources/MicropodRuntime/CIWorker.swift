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
    var buildkitSocket: URL { directory.appendingPathComponent("buildkit.sock") }
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
            "MICROPOD_CI_MAX_STARTING", "MICROPOD_CI_PORT_RELAY", "MICROPOD_CI_PORT_PROFILE",
            "MICROPOD_CI_PORT_RELAY_WORKERS", "MICROPOD_BENCH_RELAY_READ_KIB",
            "MICROPOD_CI_KERNEL", "MICROPOD_CI_PUBLISHED_PATH", "MICROPOD_CI_PUBLISHED_MTU",
            "MICROPOD_CI_PUBLISHED_RPS", "MICROPOD_CI_PUBLISHED_GSO_BYTES",
            "MICROPOD_CI_VMM", "MICROPOD_CI_HVF_BIN", "MICROPOD_CI_HVF_INITRD",
            "MICROPOD_CI_HVF_RESTORE_FROM", "MICROPOD_CI_HVF_CAPTURE_SNAPSHOT",
            "MICROPOD_TRACE",
            ObservabilityConfig.environmentKey,
            HVFKernelArguments.environmentKey,
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
        let cpus: CIWorkerCPUCount
        let memoryMiB: Int
        let diskGiB: Int
        let workspace: String?
        let ext4MaxBatchUS: Int?
        let kataTools: String?
        var kernel: String? = nil
        var publishedPath: String? = nil
        var publishedMTU: UInt32? = nil
        var publishedRPS: String? = nil
        var publishedGSOBytes: UInt32? = nil

        var engine: Engine { image == CIWorker.dockerImage ? .docker : .containerd }
    }

    struct Session: Codable, Equatable {
        let owner: RuntimeProcessBirth
        let instance: UUID
        var vmm: CIWorkerVMM?
        var guestAddress: String?
        var publishedAddress: String?
        var started = false
        var readySocket: ReadySocket?
        var workspaceDigest: String?
        var strictWorkspaceAttestation: Bool?
        var supportsNetworkRepair: Bool?
        var nativeOCI: Bool?
        var cpuAllocation: CIWorkerCPUCount.Allocation?
        var publishedRelayWorkers: Int?
        var publishedRelayCallbackEvents: Int?
        var publishedRelayReadBytes: Int?

        var activeVMM: CIWorkerVMM {
            // The first HVF supervisor wrote false here. Earlier VZ-only supervisors wrote true or omitted it.
            vmm ?? (supportsNetworkRepair == false ? .hvf : .vz)
        }
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
        public var vmm: CIWorkerVMM?
        public let daemon: String
        public let engineVersion: String
        public let guestAddress: String?
        public var publishedAddress: String? = nil
        public var publishedRelayWorkers: Int? = nil
        public var publishedRelayCallbackEvents: Int? = nil
        public var publishedRelayReadBytes: Int? = nil
        public let cpus: Int
        public var cpuSizingSource: String? = nil
        public let memoryBytes: UInt64
        public let storageDriver: String
        public var kataPrerequisitesPresent: Bool? = nil
        public let cgroupDriver: String
    }

    func prepareDirectory() throws {
        var longestSocket = socket
        if isNativeRunner {
            let vmm = try? CIWorkerVMM.parse(resourceEnvironment["MICROPOD_CI_VMM"])
            longestSocket = vmm == .hvf ? telemetrySocket : buildkitSocket
        }
        guard longestSocket.path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw MicropodError.message("CI socket path is too long: \(longestSocket.path)")
        }
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
    }

    private func cpuPolicy(existing: Configuration?) throws -> CIWorkerCPUCount {
        try resourceEnvironment["MICROPOD_CI_CPUS"].map(CIWorkerCPUCount.init) ?? existing?.cpus ?? .fixed(4)
    }

    private func plannedCPUPolicy() throws -> CIWorkerCPUCount {
        if FileManager.default.fileExists(atPath: manifest.path) { return try configuration().cpus }
        return try cpuPolicy(existing: nil)
    }

    public func cpuPlan() throws -> some Encodable {
        try plannedCPUPolicy().resolveForBoot()
    }

    public func cpuTopologyPlan() throws -> some Encodable {
        try plannedCPUPolicy().topologyPlan()
    }

    private func selectedEngine() throws -> Engine {
        let selection = resourceEnvironment["MICROPOD_CI_ENGINE"] ?? "docker"
        guard let engine = Engine(rawValue: selection) else {
            throw MicropodError.message("MICROPOD_CI_ENGINE must select containerd or docker")
        }
        return engine
    }

    private func decodeManifest(_ data: Data, engine: Engine) throws -> Configuration {
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        guard config.schema == 1, config.image == engine.image else {
            throw MicropodError.message(
                "This CI disk belongs to another engine or schema. Use a fresh MICROPOD_CI_HOME for \(engine.rawValue). "
                    + "An existing Docker disk can be reopened with MICROPOD_CI_ENGINE=docker.")
        }
        return config
    }

    /// Change the next boot's CPU policy while retaining the worker identity, disk and package caches.
    public func setCPUs(_ setting: String) throws -> some Encodable {
        let policy = try CIWorkerCPUCount(setting)
        let allocation = try policy.resolveForBoot()
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw MicropodError.message("Set MICROPOD_CI_CPUS before provisioning a new worker")
        }
        try prepareDirectory()
        guard let election = try acquire("start.lock") else { throw MicropodError.message("CI worker is starting") }
        defer { try? election.close() }
        guard let owner = try acquire() else {
            throw MicropodError.message("Drain and stop the CI worker before changing its vCPUs")
        }
        defer { try? owner.close() }
        let data = try Data(contentsOf: manifest)
        let current = try decodeManifest(data, engine: selectedEngine())
        if let override = resourceEnvironment["MICROPOD_CI_CPUS"], try CIWorkerCPUCount(override) != policy {
            throw MicropodError.message("MICROPOD_CI_CPUS conflicts with the requested worker CPU policy")
        }
        try verifyServiceCPU(policy)
        if current.cpus != policy {
            // Preserve extensions from other schema-1 binaries when editing the one requested field.
            guard var fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MicropodError.message("Invalid worker manifest")
            }
            fields["cpus"] = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(policy), options: .fragmentsAllowed)
            try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys).write(
                to: manifest, options: .atomic)
        }
        return allocation
    }

    func configuration(create: Bool = false, restoring: HVFManagedSnapshotMetadata? = nil) throws -> Configuration {
        let engine = try selectedEngine()
        let fm = FileManager.default
        let existing: Configuration?
        if fm.fileExists(atPath: manifest.path) {
            existing = try decodeManifest(Data(contentsOf: manifest), engine: engine)
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
        try restoring?.validateWorkspace(workspace)
        let batchUS = try resource("EXT4_MAX_BATCH_US", existing?.ext4MaxBatchUS ?? 15000, 0...Int(Int32.max))
        let publishedPath = resourceEnvironment["MICROPOD_CI_PUBLISHED_PATH"] ?? existing?.publishedPath
        if let publishedPath, engine != .containerd || !["bridge", "macvlan"].contains(publishedPath) {
            throw MicropodError.message("MICROPOD_CI_PUBLISHED_PATH must select bridge or macvlan on a native worker")
        }
        let publishedMTU = try
            (resourceEnvironment["MICROPOD_CI_PUBLISHED_MTU"]
            ?? existing?.publishedMTU.map { String($0) }).map { raw -> UInt32 in
                guard engine == .containerd, publishedPath == "macvlan", let mtu = UInt32(raw),
                    (1500...9000).contains(mtu)
                else {
                    throw MicropodError.message(
                        "MICROPOD_CI_PUBLISHED_MTU requires a native macvlan worker and 1500...9000 bytes")
                }
                return mtu
            }
        let publishedRPS = resourceEnvironment["MICROPOD_CI_PUBLISHED_RPS"] ?? existing?.publishedRPS
        if let publishedRPS, engine != .containerd || publishedPath != "macvlan" || publishedRPS != "off-irq" {
            throw MicropodError.message("MICROPOD_CI_PUBLISHED_RPS requires off-irq on a native macvlan worker")
        }
        let publishedGSOBytes = try
            (resourceEnvironment["MICROPOD_CI_PUBLISHED_GSO_BYTES"]
            ?? existing?.publishedGSOBytes.map { String($0) }).map { raw -> UInt32 in
                let minimum = publishedMTU ?? 1500
                guard engine == .containerd, publishedPath == "macvlan", let size = UInt32(raw),
                    (minimum...65536).contains(size)
                else {
                    throw MicropodError.message(
                        "MICROPOD_CI_PUBLISHED_GSO_BYTES requires a native macvlan worker and \(minimum)...65536 bytes")
                }
                return size
            }
        let kernel = resourceEnvironment["MICROPOD_CI_KERNEL"] ?? existing?.kernel
        if let kernel, !kernel.hasPrefix("/") {
            throw MicropodError.message("MICROPOD_CI_KERNEL requires an absolute Linux ARM64 Image path")
        }
        let config = try Configuration(
            schema: 1, image: engine.image, worker: existing?.worker ?? restoring?.workerID ?? UUID(),
            cpus: cpuPolicy(existing: existing),
            memoryMiB: resource("MEMORY_MIB", existing?.memoryMiB ?? 4096, 1024...262144),
            diskGiB: resource("DISK_GIB", existing?.diskGiB ?? 32, 4...1024), workspace: workspace,
            ext4MaxBatchUS: batchUS == 15000 ? nil : batchUS,
            kataTools: resourceEnvironment["MICROPOD_CI_KATA_TOOLS"] ?? existing?.kataTools,
            kernel: kernel, publishedPath: publishedPath == "bridge" ? nil : publishedPath, publishedMTU: publishedMTU,
            publishedRPS: publishedRPS, publishedGSOBytes: publishedGSOBytes)
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
        return try validatedDisk()
    }

    func validatedDisk() throws -> URL {
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
        let data: Data
        do {
            data = try Data(contentsOf: session)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let active: Session
        do {
            active = try JSONDecoder().decode(Session.self, from: data)
        } catch is DecodingError where !isOwned() {
            // The previous supervisor died before recording a usable session. A new owner replaces it atomically.
            return nil
        }
        guard try !active.owner.hasExited() else { return nil }
        if let raw = resourceEnvironment["MICROPOD_CI_VMM"], !raw.isEmpty {
            let requested = try selectedVMM()
            guard requested == active.activeVMM else {
                throw MicropodError.message(
                    "Requested VMM \(requested.rawValue), but the active worker uses \(active.activeVMM.rawValue) at \(directory.path)")
            }
        }
        return active
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

    private var client: DockerClient { DockerClient(endpoint: .unix(socket.path), apiVersion: Self.apiVersion) }

    public func status() async throws -> Status {
        guard FileManager.default.fileExists(atPath: session.path) else {
            throw MicropodError.message("CI worker is stopped")
        }
        try prepareDirectory()
        guard let active = try liveSession() else { throw MicropodError.message("CI worker is stopped") }
        guard active.started else { throw MicropodError.message("CI worker is booting") }
        return try await inspectEngine(active, config: runningConfiguration(active))
    }

    private func runningConfiguration(_ active: Session) throws -> Configuration {
        let config = try configuration()
        if active.activeVMM == .hvf {
            let expected = HVFKernelArguments.workspaceDigest(
                config.workspace, strict: active.strictWorkspaceAttestation == true)
            guard active.workspaceDigest == expected else {
                throw MicropodError.message(
                    "The active HVF worker did not attest the configured workspace. Restart it with matching components."
                )
            }
        }
        return config
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
            let count: Int
            if let allocation = active.cpuAllocation {
                count = allocation.count
            } else if case .fixed(let previous) = config.cpus {
                count = previous  // Session from a supervisor predating boot-time sizing.
            } else {
                throw MicropodError.message("The active runner has no boot CPU allocation")
            }
            return Status(
                endpoint: endpoint, worker: config.worker, boot: identity.boot, instance: active.instance,
                engine: "containerd", vmm: active.activeVMM, daemon: identity.engine, engineVersion: identity.version,
                guestAddress: active.guestAddress, publishedAddress: active.publishedAddress,
                publishedRelayWorkers: active.publishedRelayWorkers,
                publishedRelayCallbackEvents: active.publishedRelayCallbackEvents,
                publishedRelayReadBytes: active.publishedRelayReadBytes, cpus: count,
                cpuSizingSource: active.cpuAllocation?.source.rawValue,
                memoryBytes: identity.memory_bytes,
                storageDriver: "overlayfs", kataPrerequisitesPresent: identity.kata_prerequisites_present,
                cgroupDriver: "cgroupfs")
        }
        let response = try await client.request("GET", "/info", timeout: .seconds(2))
        guard response.status == 200 else { throw MicropodError.message("CI engine: \(response.message)") }
        let info = try JSONDecoder().decode(Info.self, from: response.body)
        if let expected = active.cpuAllocation?.count, info.NCPU != expected {
            throw MicropodError.message("Docker reports \(info.NCPU) CPUs on a worker booted with \(expected)")
        }
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
            engine: config.engine.rawValue, vmm: active.activeVMM,
            daemon: info.ID, engineVersion: info.ServerVersion, guestAddress: active.guestAddress,
            publishedAddress: active.publishedAddress, publishedRelayWorkers: active.publishedRelayWorkers,
            publishedRelayCallbackEvents: active.publishedRelayCallbackEvents,
            publishedRelayReadBytes: active.publishedRelayReadBytes, cpus: info.NCPU,
            cpuSizingSource: active.cpuAllocation?.source.rawValue,
            memoryBytes: info.MemTotal, storageDriver: info.Driver,
            cgroupDriver: info.CgroupDriver)
    }

    static func hostname(_ instance: UUID) -> String { "mp-" + instance.uuidString.lowercased() }

    /// The client checks liveness when it submits the job. Its endpoint is attested once per boot.
    public func runEndpoint(executable: URL) async throws -> String {
        try prepareDirectory()
        if let active = try liveSession(), active.started, let verified = active.readySocket,
            !FileManager.default.fileExists(atPath: stopFile(active).path),
            ReadySocket(at: socket, worker: try runningConfiguration(active).worker) == verified
        {
            return endpoint
        }
        return try await start(executable: executable).endpoint
    }

    /// Verify the Docker API for an already running worker.
    func dockerStatus() async throws -> (engineVersion: String, supportsRestart: Bool) {
        let active = try await status()
        if active.engine == Engine.containerd.rawValue {
            return (active.engineVersion, try await attestNativeDocker(active))
        }
        return (active.engineVersion, true)
    }

    public func nativeDockerEndpoint(executable: URL) async throws -> String {
        let active = try await start(executable: executable)
        _ = try await attestNativeDocker(active)
        return "unix://" + dockerSocket.path
    }

    /// The native worker exposes Docker separately from its OCI control socket.
    private func attestNativeDocker(_ active: Status) async throws -> Bool {
        let api = DockerClient(endpoint: .unix(dockerSocket.path), apiVersion: Self.apiVersion)
        let reply = try await api.request("GET", "/info", timeout: .seconds(3))
        return try Self.attestedDockerRestart(reply, worker: active.worker, instance: active.instance)
    }

    static func attestedDockerRestart(_ reply: DockerClient.Response, worker: UUID, instance: UUID) throws -> Bool {
        guard reply.status == 200, let info = try reply.json() as? [String: Any],
            info["ID"] as? String == worker.uuidString,
            (info["Labels"] as? [String])?.contains("io.micropod.instance=" + instance.uuidString) == true
        else { throw MicropodError.message("Native Docker API did not identify the active worker") }
        return (info["MicropodCapabilities"] as? [String])?.contains("restart") == true
    }

    public func nativeBuildKitEndpoint(executable: URL) async throws -> String {
        _ = try await nativeDockerEndpoint(executable: executable)
        let api = DockerClient(endpoint: .unix(dockerSocket.path), apiVersion: Self.apiVersion)
        let reply = try await api.request("GET", "/micropod/buildkit", timeout: .seconds(5))
        guard reply.status == 200, FileManager.default.fileExists(atPath: buildkitSocket.path) else {
            throw MicropodError.message("The active worker needs a native tool bundle with BuildKit")
        }
        return "unix://" + buildkitSocket.path
    }

    public func start(executable: URL) async throws -> Status {
        try prepareDirectory()
        _ = try selectedVMM()
        if FileManager.default.fileExists(atPath: manifest.path) { _ = try configuration() }
        let deadline = ContinuousClock.now + .seconds(180)
        var election: FileHandle?
        var child: Process?
        var launchdDeadline: ContinuousClock.Instant?
        var sawSupervisor = false
        defer { try? election?.close() }
        repeat {
            if let active = try liveSession() {
                guard !FileManager.default.fileExists(atPath: stopFile(active).path) else {
                    throw MicropodError.message("CI worker is stopping")
                }
                sawSupervisor = true
                if active.started {
                    let config = try runningConfiguration(active)
                    if let current = try? await inspectEngine(active, config: config) { return current }
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
                if try liveSession() == nil {
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
        let api = DockerClient(endpoint: .unix(ociSocket.path), apiVersion: "oci/v1")
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
        let api = DockerClient(endpoint: .unix(endpoint.path), apiVersion: Self.apiVersion)
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
        let stopped = directory.appendingPathComponent("stopped")
        let expectedReceipt = Data(active.instance.uuidString.utf8)
        while ContinuousClock.now < deadline {
            let exited = try active.owner.hasExited()
            let acknowledged = (try? Data(contentsOf: stopped)) == expectedReceipt
            if exited {
                guard acknowledged else {
                    throw MicropodError.message("CI supervisor exited without confirming a clean shutdown")
                }
                return
            }
            // A foreground supervisor can stay in its parent's process table until waitpid.
            // The per-boot receipt and released lifetime lock already establish that teardown finished.
            if acknowledged && !isOwned() { return }
            if !FileManager.default.fileExists(atPath: request.path), try liveSession() != nil {
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
        let vmm = try selectedVMM()
        if vmm == .vz {
            guard VZVirtualMachine.isSupported else {
                throw MicropodError.message("Apple Virtualization is unavailable on this Mac")
            }
        }
        // This check belongs to a new supervisor launch. Clients can rejoin an
        // active restored session after the VMM creates its writable disk.
        let restoreSource = vmm == .hvf ? try hvfRestoreSource() : nil
        let restoreDisk = try restoreSource.map { _ in try freshHVFRestoreDisk() }
        let config = try configuration(create: true, restoring: restoreSource?.metadata)
        if vmm == .hvf, let workspace = config.workspace {
            _ = try HVFKernelArguments.workspaceArgument(workspace)
        }
        guard let owner = try RuntimeProcessBirth.read(getpid()) else {
            throw MicropodError.message("Missing supervisor identity")
        }
        let cpuAllocation = try config.cpus.resolveForBoot()
        var active = Session(
            owner: owner, instance: UUID(), vmm: vmm, supportsNetworkRepair: vmm == .vz, cpuAllocation: cpuAllocation)
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

        if vmm == .hvf {
            guard let ociTools = try nativeTools(engine: config.engine) else {
                throw MicropodError.message(
                    "Containerd runner tools are missing. Build or install ci/build-runner-tools.sh first.")
            }
            let captureDir = hvfCaptureSnapshotDirectory()
            let captureTrigger = captureDir.map { _ in
                directory.appendingPathComponent("snapshot-\(UUID().uuidString).trigger")
            }
            defer {
                if let captureTrigger { try? FileManager.default.removeItem(at: captureTrigger) }
            }
            if let (_, meta) = restoreSource {
                guard meta.cpus == cpuAllocation.count, meta.memoryMiB == config.memoryMiB,
                    meta.publishedMTU == (config.publishedMTU ?? 9000)
                else {
                    throw MicropodError.message(
                        "HVF warm snapshot topology (\(meta.cpus) vCPU, \(meta.memoryMiB) MiB, MTU \(meta.publishedMTU)) "
                            + "does not match worker config (\(cpuAllocation.count) vCPU, \(config.memoryMiB) MiB, MTU \(config.publishedMTU ?? 9000))")
                }
                guard meta.workerID == config.worker else {
                    throw MicropodError.message(
                        "HVF warm snapshot worker ID \(meta.workerID.uuidString) differs from \(manifest.path); use a fresh MICROPOD_CI_HOME")
                }
                // A warm fork keeps the captured guest worker, instance, and boot identity.
                // Each launch owns its own supervisor, Unix endpoints and writable disk.
                active = Session(
                    owner: owner, instance: meta.instanceID, vmm: vmm, supportsNetworkRepair: false,
                    cpuAllocation: cpuAllocation)
            }
            active.nativeOCI = true
            let strictWorkspace = restoreSource != nil || captureDir != nil
            if strictWorkspace { active.strictWorkspaceAttestation = true }
            let diskURL: URL
            if let restoreDisk {
                // micropod-vmm instantly APFS CoW-clones <snapshot>/disk.ext4 -> diskURL before opening it.
                diskURL = restoreDisk
            } else if FileManager.default.fileExists(atPath: disk.path) {
                diskURL = try validatedDisk()
            } else {
                let image = try await SandboxVM.resolveCIImage(
                    config.image, progress: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
                diskURL = try await openDisk(
                    image: image, bytes: UInt64(config.diskGiB) << 30,
                    progress: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
            }
            let proc = try launchHVFProcess(
                config: config, instanceID: active.instance, cpus: cpuAllocation.count,
                diskURL: diskURL, ociTools: ociTools,
                restoreFrom: restoreSource?.directory,
                snapshotOut: captureDir,
                snapshotTrigger: captureTrigger)
            let stopHVF = {
                if proc.isRunning {
                    proc.terminate()
                    proc.waitUntilExit()
                }
            }
            do {
                active.guestAddress = "10.42.0.2"
                active.publishedAddress = "10.43.0.2"
                let readyStart = ContinuousClock.now
                let readyBy = readyStart + .seconds(90)
                let api = DockerClient(endpoint: .unix(dockerSocket.path), apiVersion: Self.apiVersion)
                while true {
                    guard proc.isRunning else {
                        throw MicropodError.message("micropod-vmm exited early (\(proc.terminationStatus))")
                    }
                    if let reply = try? await api.request("GET", "/info", timeout: .seconds(2)),
                        reply.status == 200, let info = try? reply.json() as? [String: Any],
                        info["ID"] as? String == config.worker.uuidString,
                        let labels = info["Labels"] as? [String],
                        labels.contains("io.micropod.instance=" + active.instance.uuidString)
                    {
                        active.workspaceDigest = try HVFKernelArguments.attestWorkspace(
                            config.workspace, labels: labels, strict: strictWorkspace)
                        break
                    }
                    guard ContinuousClock.now < readyBy else {
                        throw MicropodError.message("HVF worker Docker API did not become ready")
                    }
                    let pollInterval: Duration =
                        ContinuousClock.now - readyStart < .milliseconds(250) ? .milliseconds(5) : .milliseconds(25)
                    try await Task.sleep(for: pollInterval)
                }
                if let captureDir, let captureTrigger {
                    let meta = HVFManagedSnapshotMetadata(
                        workerID: config.worker, instanceID: active.instance, cpus: cpuAllocation.count,
                        memoryMiB: config.memoryMiB, publishedMTU: config.publishedMTU ?? 9000,
                        workspace: config.workspace, diskBytes: try HVFManagedSnapshotMetadata.ext4FileSize(diskURL))
                    try meta.write(to: captureDir)
                    let readyMarker = captureDir.appendingPathComponent("READY")
                    try Data("capture\n".utf8).write(to: captureTrigger, options: .atomic)
                    let snapDeadline = ContinuousClock.now + .seconds(20)
                    while !FileManager.default.fileExists(atPath: readyMarker.path) {
                        guard proc.isRunning else {
                            throw MicropodError.message("micropod-vmm exited during snapshot capture")
                        }
                        guard ContinuousClock.now < snapDeadline else {
                            throw MicropodError.message("Timed out capturing HVF warm snapshot at \(captureDir.path)")
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    _ = try HVFManagedSnapshotMetadata.load(from: captureDir)
                }
                active.readySocket = ReadySocket(at: socket, worker: config.worker)
                active.started = true
                try JSONEncoder().encode(active).write(to: session, options: .atomic)
                proc.terminationHandler = { p in
                    stream.yield(.exited("exit \(p.terminationStatus)"))
                }
                var stopping = false
                hvfLoop: for await event in events {
                    switch event {
                    case .exited(let reason):
                        guard stopping else { throw MicropodError.message("HVF CI worker stopped: \(reason)") }
                        break hvfLoop
                    case .maintenance:
                        guard !stopping, FileManager.default.fileExists(atPath: stopFile(active).path),
                            try await drain(active)
                        else { continue }
                        stopping = true
                        proc.terminate()
                    case .terminate:
                        if stopping { continue }
                        stopping = true
                        proc.terminate()
                    case .checkNetwork, .timedOut:
                        continue
                    }
                }
            } catch {
                stopHVF()
                throw error
            }
            stopHVF()
            try Data(active.instance.uuidString.utf8).write(
                to: directory.appendingPathComponent("stopped"), options: .atomic)
            return 0
        }

        var options = SandboxVM.Options(base: .image(config.image))
        options.network = true
        options.hostname = config.engine == .containerd ? Self.hostname(active.instance) : "micropod-ci"
        let portRelay = try CIWorkerPortRelay(
            mode: resourceEnvironment["MICROPOD_CI_PORT_RELAY"],
            workers: resourceEnvironment["MICROPOD_CI_PORT_RELAY_WORKERS"])
        if config.publishedPath == "macvlan", !portRelay.usesKqueue {
            throw MicropodError.message("Direct published ports require the native kqueue relay")
        }
        options.ciWorkspace = config.workspace
        options.ciPublishedMTU = config.publishedMTU
        options.ciPublishedGSOBytes = config.publishedGSOBytes
        options.ciKernel = config.kernel.map { URL(fileURLWithPath: $0) }
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
        options.cpus = cpuAllocation.count
        options.memoryMiB = UInt64(config.memoryMiB)
        options.diskBytes = UInt64(config.diskGiB) << 30
        options.env = [
            "MICROPOD_CI_WORKER_ID=" + config.worker.uuidString, "MICROPOD_CI_INSTANCE=" + active.instance.uuidString,
        ]
        if active.nativeOCI == true { options.env.append("MICROPOD_NATIVE_OCI=1") }
        if config.engine == .containerd {
            options.env.append("MICROPOD_ENGINE_API=1")
            if let path = config.publishedPath { options.env.append("MICROPOD_CI_PUBLISHED_PATH=" + path) }
            if let rps = config.publishedRPS { options.env.append("MICROPOD_CI_PUBLISHED_RPS=" + rps) }
            if let size = config.publishedGSOBytes {
                options.env.append("MICROPOD_CI_PUBLISHED_GSO_BYTES=" + String(size))
            }
            if portRelay.dataWorkers > 0 { options.env.append("MICROPOD_CI_PORT_THROUGHPUT=1") }
            if let raw = resourceEnvironment["MICROPOD_CI_MAX_STARTING"] {
                guard let limit = Int(raw), (0...32).contains(limit) else {
                    throw MicropodError.message("MICROPOD_CI_MAX_STARTING must be between 0 and 32")
                }
                options.env.append("MICROPOD_CI_MAX_STARTING=" + String(limit))
            }
            if let workspace = config.workspace { options.env.append("MICROPOD_ENGINE_WORKSPACE=" + workspace) }
        }
        options.entrypoint = ["/bin/sh", "-c"]
        options.arguments = [config.engine == .containerd ? "exec /opt/micropod-oci/runner/start.sh" : Self.bootstrap]

        let prepared = try await SandboxVM.prepare(
            options, id: "ci-" + active.instance.uuidString.lowercased(), runDir: directory,
            stdout: FileHandleWriter(.standardOutput), stderr: FileHandleWriter(.standardError),
            progress: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }, ciWorker: self)
        do {
            let nativeRelay: NativeLoopbackRelay?
            if config.engine == .containerd, let guest = prepared.guestIP, let gateway = prepared.gateway {
                let link = prepared.publishedNetwork
                active.publishedAddress = link?.interface.ipv4Address.address.description
                nativeRelay = try await prepared.forwarding.openNativePortBroker(
                    at: portSocket, guest: active.publishedAddress ?? guest,
                    gateway: link?.gateway.description ?? gateway,
                    relayConfig: portRelay,
                    profile: resourceEnvironment["MICROPOD_CI_PORT_PROFILE"] == "1")
                active.publishedRelayWorkers = nativeRelay?.dataWorkerCount
                active.publishedRelayCallbackEvents = nativeRelay?.dataCallbackEvents
                active.publishedRelayReadBytes = nativeRelay?.readBytes
            } else {
                nativeRelay = nil
            }
            try await prepared.container.create()
            guard chmod(socket.path, 0o600) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            if chmod(dockerSocket.path, 0o600) != 0
                || active.nativeOCI == true
                    && (chmod(ociSocket.path, 0o600) != 0 || chmod(buildkitSocket.path, 0o600) != 0)
            {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            try await prepared.container.start()
            active.guestAddress = prepared.guestIP
            let readyBy = ContinuousClock.now + .seconds(config.engine == .containerd ? 135 : 40)
            while (try? await inspectEngine(active, config: config)) == nil {
                guard ContinuousClock.now < readyBy else {
                    throw MicropodError.message("Guest container engine did not become ready after boot")
                }
                try await Task.sleep(for: .milliseconds(25))
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
                        try await Task.sleep(for: .milliseconds(25))
                    }
                }
            }
            if config.engine == .containerd {
                let api = DockerClient(endpoint: .unix(dockerSocket.path), apiVersion: Self.apiVersion)
                while true {
                    if let reply = try? await api.request("GET", "/info", timeout: .seconds(2)),
                        reply.status == 200, let info = try? reply.json() as? [String: Any],
                        info["ID"] as? String == config.worker.uuidString,
                        let labels = info["Labels"] as? [String],
                        labels.contains("io.micropod.instance=" + active.instance.uuidString)
                    {
                        guard info["NCPU"] as? Int == cpuAllocation.count else {
                            throw MicropodError.message(
                                "Native Docker API CPU count differs from the worker boot allocation")
                        }
                        if config.publishedPath == "macvlan", !labels.contains("io.micropod.published-path=macvlan") {
                            throw MicropodError.message("The installed guest tools did not enable direct macvlan ports")
                        }
                        break
                    }
                    guard ContinuousClock.now < readyBy else {
                        throw MicropodError.message("The native Docker API did not recover on this worker boot")
                    }
                    try await Task.sleep(for: .milliseconds(25))
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
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    stream.yield(.checkNetwork)
                }
            }
            let instanceID = active.instance
            let networkWatch = NetworkWatch()
            let publishedWatch = NetworkWatch()
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
                        // Egress repair may wait on vmnet. Check the independent
                        // published link concurrently, including during explicit repairs.
                        let failedHandshake = nativeRelay?.takePathFailure() == true
                        let dedicatedLink = prepared.publishedNetwork != nil
                        let publishedRelay = nativeRelay
                        async let published = publishedWatch.inspect(
                            prepared, gateway: prepared.publishedNetwork?.gateway.description ?? gateway,
                            instance: instanceID, request: nil, link: .published,
                            failedHandshake: dedicatedLink && failedHandshake, publishedRelay: publishedRelay)
                        if let receipt = await networkWatch.inspect(
                            prepared, gateway: gateway, instance: active.instance, request: token,
                            failedHandshake: !dedicatedLink && failedHandshake)
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
                        if let receipt = await published {
                            do {
                                try JSONEncoder().encode(receipt).write(
                                    to: directory.appendingPathComponent("published-network.json"), options: .atomic)
                            } catch { SecretSource.stderrLog("Could not record published network repair: \(error)") }
                            SecretSource.stderrLog("Published network repair: " + (receipt.error ?? "gateway restored"))
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
