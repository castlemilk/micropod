import Foundation
import MicropodCore

/// `ContainerServing` backed by direct XPC calls to `container-apiserver`.
///
/// Everything except interactive/TTY flows goes over one persistent XPC
/// connection — no process spawn, no CLI arg parsing. `create`/`run`
/// reimplement the client side of `container create` (image resolution →
/// OCI config → `ContainerConfiguration`) in ``NativeConfigBuilder``.
///
/// `prune`, `cp`, and interactive/TTY flows still delegate to the
/// embedded CLI service.
public struct NativeContainerService: ContainerServing {
    private let api: APIServerClient
    private let images: ImagesServiceClient
    /// CLI fallback for operations not mapped natively.
    private let cli: ContainerService
    /// Volume-mount policy — resolved per create so a policy change in
    /// the app/API applies without restarting this process.
    private let policy: @Sendable () -> VolumePolicy

    public init(
        api: APIServerClient, cli: ContainerService,
        images: ImagesServiceClient = ImagesServiceClient(),
        policy: @escaping @Sendable () -> VolumePolicy = { VolumePolicyStore.load() }
    ) {
        self.api = api
        self.cli = cli
        self.images = images
        self.policy = policy
    }

    public func list() async throws -> [Micropod_V1_Container] {
        let data = try await api.list()
        let entries = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: data, context: "container list")
        return entries.map(ModelMapper.container(from:))
    }

    public func inspect(_ id: String) async throws -> Data {
        guard let data = try await api.get(id: id) else {
            throw MicropodError.message("container \(id) not found")
        }
        return data
    }

    public func create(_ request: ContainerRunRequest) async throws -> String {
        if request.tty || request.interactive {
            // TTY/interactive needs a real pty wired through ProcessIO —
            // keep the CLI path for those.
            return try await cli.create(request)
        }
        return try await createNative(request)
    }

    public func run(_ request: ContainerRunRequest) async throws -> String {
        if request.tty || request.interactive || !request.detach {
            // Interactive/TTY needs a pty; non-detached runs attach and
            // stream output — both are ProcessIO concerns the CLI owns.
            return try await cli.run(request)
        }
        let id = try await createNative(request)
        do {
            try await api.bootstrap(id: id)
            try await api.startProcess(containerId: id, processId: id)
        } catch {
            // Match the CLI: a failed start cleans up the created container.
            try? await api.delete(id: id, force: true)
            Self.removeClones(containerID: id)
            throw error
        }
        return id
    }

    /// Native `container create`: resolve image → build
    /// `ContainerConfiguration` → `containerCreate` XPC.
    private func createNative(_ request: ContainerRunRequest) async throws -> String {
        let id = request.name ?? UUID().uuidString.lowercased()
        do {
            return try await createNativeInner(request, id: id)
        } catch {
            Self.removeClones(containerID: id)
            throw error
        }
    }

    private func createNativeInner(_ request: ContainerRunRequest, id: String) async throws -> String {
        let sysConfig = NativeConfigBuilder.loadSystemConfig()
        let platform = try NativeConfigBuilder.ociPlatform(request.platform)

        // Image resolution (ClientImage.fetch): local match or pull.
        let imageDescription = try await images.ensure(
            reference: request.image,
            platform: platform,
            registryDomain: sysConfig.registryDomain
        )
        let imageConfig = try await images.imageConfig(description: imageDescription, platform: platform)

        // Mounts — named volumes resolve through the apiserver's volume
        // routes (getOrCreate, like the CLI). Volumes selected for cloning
        // (per-container `com.micropod.cache.clone` label, else the shared
        // VolumePolicy) are clonefile-forked: the golden .img is APFS-
        // cloned per container and attached as a raw `.block` mount —
        // same attach path server-side, but the golden stays pristine and
        // each container gets isolated writes at ext4 speed. Clones
        // default to `nosync` (scratch semantics); `com.micropod.volume.
        // sync`/`.cache` labels and the policy tune all block mounts.
        let labelMap = Self.labelMap(request.labels)
        let policy = self.policy()
        let cloneSet = policy.cloneSet(labels: labelMap)
        if !cloneSet.isEmpty {
            let entries = await listEntries()
            // Self-heal: a clone dir orphaned by a raw `container delete`
            // (or a crashed runtime) is swept on the next cloning create.
            sweepOrphanClones(live: Set(entries.map(\.id)))
            warnIfGoldensInUse(cloneSet, entries: entries)
        }
        var mounts: [JSONValue] = []
        for mount in try NativeConfigBuilder.parseMounts(request: request) {
            switch mount {
            case .tmpfs(let destination, let options):
                mounts.append(
                    NativeConfigBuilder.filesystemObject(
                        type: "tmpfs", typeFields: [:], source: "tmpfs",
                        destination: destination, options: options))
            case .virtiofs(let source, let destination, let options):
                mounts.append(
                    NativeConfigBuilder.filesystemObject(
                        type: "virtiofs", typeFields: [:], source: source,
                        destination: destination, options: options))
            case .volume(let name, let destination, let options):
                // The `.volume` reply is a flat VolumeConfiguration
                // ({name,format,source,…}) — the {id,configuration}
                // wrapper is only how `volume inspect` pretty-prints.
                // FSType encodes enums as nested case objects, so
                // cache/sync are {"on":{}} / {"fsync":{}} not strings.
                if cloneSet.contains(name) || cloneSet.contains("*") {
                    guard let volume = try await api.volumeInspect(name: name) else {
                        throw MicropodError.message(
                            "cache clone source volume '\(name)' not found")
                    }
                    let format = NativeConfigBuilder.string(volume["format"]) ?? "ext4"
                    let source = NativeConfigBuilder.string(volume["source"]) ?? ""
                    guard !source.isEmpty else {
                        throw MicropodError.message(
                            "cache clone source volume '\(name)' has no backing image")
                    }
                    let clone = try Self.cloneVolumeImage(
                        source: source, containerID: id, volume: name)
                    mounts.append(
                        NativeConfigBuilder.filesystemObject(
                            type: "block",
                            typeFields: [
                                "format": .string(format),
                                "cache": .object([policy.cacheCase(labels: labelMap): .object([:])]),
                                "sync": .object([
                                    policy.syncCase(labels: labelMap, fallback: "nosync"):
                                        .object([:])
                                ]),
                            ],
                            source: clone,
                            destination: destination, options: options))
                } else {
                    let volume = try await api.getOrCreateVolume(name: name)
                    mounts.append(
                        NativeConfigBuilder.filesystemObject(
                            type: "volume",
                            typeFields: [
                                "name": .string(name),
                                "format": volume["format"] ?? .string("ext4"),
                                "cache": .object([policy.cacheCase(labels: labelMap): .object([:])]),
                                "sync": .object([
                                    policy.syncCase(labels: labelMap, fallback: "fsync"):
                                        .object([:])
                                ]),
                            ],
                            source: NativeConfigBuilder.string(volume["source"]) ?? "",
                            destination: destination, options: options))
                }
            }
        }

        // Networks — default attaches to the builtin network.
        let networkResources = try await api.networkList()
        let attachments = try NativeConfigBuilder.attachments(
            request: request,
            containerID: id,
            builtinNetworkID: APIServerClient.builtinNetworkID(in: networkResources),
            dnsDomain: sysConfig.dnsDomain,
            existingNetworks: APIServerClient.networkIDs(in: networkResources)
        )

        let memoryBytes: UInt64 =
            if let memory = request.memory {
                try NativeConfigBuilder.memoryToBytes(memory)
            } else {
                UInt64(sysConfig.containerMemory) * 1024 * 1024
            }

        // Rosetta: explicit request, or arm64 host running amd64 image.
        let hostArm64 = NativeConfigBuilder.hostArchitecture == "arm64"
        var imageAmd64 = false
        if case .string(let arch) = platform["architecture"], arch == "amd64" {
            imageAmd64 = true
        }
        let rosetta = request.rosetta || (hostArm64 && imageAmd64)

        var config: [String: JSONValue] = [
            "id": .string(id),
            "image": imageDescription,
            "initProcess": try NativeConfigBuilder.initProcess(request: request, imageConfig: imageConfig?.config),
            "mounts": .array(mounts),
            "networks": .array(attachments),
            "labels": .object(NativeConfigBuilder.labels(request.labels)),
            "publishedPorts": .array(try NativeConfigBuilder.publishedPorts(request.publishedPorts)),
            "publishedSockets": .array([]),
            "sysctls": .object([:]),
            "platform": platform,
            "resources": .object([
                "cpus": .number(Double(request.cpus.map(Int.init) ?? sysConfig.containerCPUs)),
                "memoryInBytes": .number(Double(memoryBytes)),
                "cpuOverhead": .number(1),
            ]),
            "runtimeHandler": .string("container-runtime-linux"),
            "rosetta": .bool(rosetta),
            "virtualization": .bool(false),
            "ssh": .bool(false),
            "readOnly": .bool(request.readOnly),
            "useInit": .bool(request.useInit),
            "capAdd": .array(NativeConfigBuilder.normalizeCapabilities(request.capAdd)),
            "capDrop": .array(NativeConfigBuilder.normalizeCapabilities(request.capDrop)),
            "creationDate": .number(Date().timeIntervalSinceReferenceDate),
        ]

        // DNS: omitted only when the request disables it — Micropod has
        // no --no-dns flag, so always emit (possibly empty) DNS config.
        var dns: [String: JSONValue] = [
            "nameservers": .array(request.dns.map { .string($0) }),
            "searchDomains": .array(request.dnsSearch.map { .string($0) }),
            "options": .array([]),
        ]
        if let domain = sysConfig.dnsDomain {
            dns["domain"] = .string(domain)
        }
        config["dns"] = .object(dns)

        if let shm = request.shmSize {
            config["shmSize"] = .number(Double(try NativeConfigBuilder.memoryToBytes(shm)))
        }
        if let stopSignal = imageConfig?.config?.stopSignal {
            config["stopSignal"] = .string(stopSignal)
        }

        let kernel = try await api.getDefaultKernel(
            systemPlatform: NativeConfigBuilder.systemPlatform())
        try await api.create(
            configJSON: .object(config),
            kernel: kernel,
            options: .object(["autoRemove": .bool(false)]),
            initImage: nil
        )
        return id
    }

    public func exec(_ request: ContainerExecRequest) async throws -> String {
        let result = try await execDetailed(request)
        if result.exitCode != 0 {
            throw MicropodError.cliFailure(
                command: "container exec \(request.containerID)",
                exitCode: result.exitCode,
                stderr: result.error
            )
        }
        return result.output
    }

    public func execDetailed(_ request: ContainerExecRequest) async throws -> ContainerExecResult {
        // Interactive/TTY exec stays on the CLI path — it needs a real pty
        // wired to the caller's terminal, which ProcessIO handles there.
        if request.tty || request.interactive {
            return try await cli.execDetailed(request)
        }
        guard let executable = request.arguments.first else {
            throw MicropodError.message("exec requires a command")
        }

        let managed = try await api.managed(id: request.containerID)
        let config = try ProcessConfigPatch.patch(
            managedJSON: managed,
            executable: executable,
            arguments: Array(request.arguments.dropFirst()),
            appendEnvironment: request.env,
            workingDirectory: request.workdir,
            terminal: false,
            user: request.user
        )

        let stdout = Pipe()
        let stderr = Pipe()
        let processId = UUID().uuidString.lowercased()

        try await api.createProcess(
            containerId: request.containerID,
            processId: processId,
            configJSON: config,
            stdio: [nil, stdout.fileHandleForWriting, stderr.fileHandleForWriting]
        )
        // Our copies of the write ends must close so reads see EOF when the
        // guest closes its side on process exit.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        if request.detach {
            try await api.startProcess(containerId: request.containerID, processId: processId)
            return ContainerExecResult(output: request.containerID, error: "", exitCode: 0)
        }

        // Stdio arrives asynchronously: guest → vsock → runtime helper →
        // our pipe, and the helper's fd close (EOF) can lag — or never
        // arrive — past `containerWait`. The CLI's ProcessIO bounds the
        // post-exit EOF wait at 3s; we do the same. Reads are nonblocking
        // polls so a never-EOF can't deadlock us, and they run during the
        // process so large outputs can't fill the pipe and stall the guest.
        let outRead = stdout.fileHandleForReading
        let errRead = stderr.fileHandleForReading
        Self.setNonblocking(outRead)
        Self.setNonblocking(errRead)

        try await api.startProcess(containerId: request.containerID, processId: processId)

        let drainer = Task {
            var out = Data()
            var err = Data()
            while !Task.isCancelled {
                out.append(Self.readSome(outRead) ?? Data())
                err.append(Self.readSome(errRead) ?? Data())
                try? await Task.sleep(for: .milliseconds(10))
            }
            return (out, err)
        }

        let exitCode = try await api.waitProcess(
            containerId: request.containerID, processId: processId)
        drainer.cancel()
        var (out, err) = await drainer.value

        // Post-exit: drain until both fds hit EOF or the 3s cap — whichever
        // comes first (matching ProcessIO's EOF-wait timeout). EOF is not
        // guaranteed: any process spawned while the apiserver holds the fd
        // inherits a copy, so the pipe can stay open indefinitely. In-flight
        // data arrives within milliseconds of exit, so a 100ms quiet window
        // is the practical bound — don't burn the full cap on every exec.
        let deadline = ContinuousClock.now + .seconds(3)
        var lastData = ContinuousClock.now
        var outEOF = false
        var errEOF = false
        while !outEOF || !errEOF, ContinuousClock.now < deadline {
            var got = false
            if !outEOF, let chunk = Self.readSome(outRead) {
                if chunk.isEmpty {
                    outEOF = true
                } else {
                    out.append(chunk)
                    got = true
                }
            }
            if !errEOF, let chunk = Self.readSome(errRead) {
                if chunk.isEmpty {
                    errEOF = true
                } else {
                    err.append(chunk)
                    got = true
                }
            }
            if got {
                lastData = .now
            } else if ContinuousClock.now - lastData > .milliseconds(100) {
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }

        return ContainerExecResult(
            output: String(decoding: out, as: UTF8.self),
            error: String(decoding: err, as: UTF8.self),
            exitCode: exitCode
        )
    }

    public func start(_ id: String) async throws {
        // bootstrap boots the VM and waits for vminitd; the init process
        // is only started by containerStartProcess with processId == id —
        // that's also what flips the apiserver's status to `running`.
        try await api.bootstrap(id: id)
        try await api.startProcess(containerId: id, processId: id)
    }

    public func stop(_ id: String, timeout: Int = 10) async throws {
        try await api.stop(id: id, timeoutSeconds: Int32(timeout))
    }

    public func restart(_ id: String) async throws {
        try await stop(id, timeout: 10)
        try await start(id)
    }

    public func stopAll() async throws {
        // No bulk-stop route; stop each running container concurrently.
        let entries = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: await api.list(status: "running"),
            context: "container list")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for entry in entries {
                group.addTask { try await self.api.stop(id: entry.id) }
            }
            try await group.waitForAll()
        }
    }

    public func kill(_ id: String, signal: String = "KILL") async throws {
        try await api.killContainer(id: id, signal: signal)
    }

    public func delete(_ id: String, force: Bool = false) async throws {
        try await api.delete(id: id, force: force)
        Self.removeClones(containerID: id)
    }

    public func deleteAll(force: Bool = false) async throws {
        let entries = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: await api.list(), context: "container list")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for entry in entries {
                group.addTask {
                    try await self.api.delete(id: entry.id, force: force)
                    Self.removeClones(containerID: entry.id)
                }
            }
            try await group.waitForAll()
        }
    }

    /// `container prune` — the CLI composes list(stopped) → diskUsage →
    /// delete; every route it uses is native here.
    public func prune() async throws -> String {
        let entries = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: await api.list(status: "stopped"),
            context: "container list")
        var pruned: [String] = []
        var totalSize: UInt64 = 0
        for entry in entries {
            do {
                totalSize += (try? await api.diskUsage(id: entry.id)) ?? 0
                try await api.delete(id: entry.id)
                Self.removeClones(containerID: entry.id)
                pruned.append(entry.id)
            } catch {
                continue
            }
        }
        // Orphan sweep: clone dirs whose container is already gone (e.g.
        // deleted via the raw `container` CLI) would otherwise leak.
        sweepOrphanClones(live: Set((await listEntries()).map(\.id)))
        let freed = ByteCountFormatter().string(fromByteCount: Int64(totalSize))
        return pruned.joined(separator: "\n") + (pruned.isEmpty ? "" : "\nReclaimed \(freed) in disk space")
    }

    public func export(_ id: String, to outputPath: String) async throws {
        try await api.export(id: id, archivePath: outputPath)
    }

    /// Native `container cp` — same `id:/abs/path` grammar as the CLI.
    /// Copying between two containers, or two local paths, is rejected.
    public func copy(from: String, to: String) async throws {
        enum Ref {
            case local(String)
            case container(id: String, path: String)
        }
        func parse(_ raw: String) throws -> Ref {
            let parts = raw.components(separatedBy: ":")
            switch parts.count {
            case 1:
                return .local(raw)
            case 2 where !parts[0].isEmpty && parts[1].hasPrefix("/"):
                return .container(id: parts[0], path: parts[1])
            default:
                throw MicropodError.message("invalid path given: \(raw)")
            }
        }
        let fm = FileManager.default
        switch (try parse(from), try parse(to)) {
        case (.container(let id, let path), .local(let localPath)):
            var dest = URL(fileURLWithPath: localPath).standardizedFileURL.path
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dest, isDirectory: &isDir), isDir.boolValue {
                dest = (dest as NSString).appendingPathComponent((path as NSString).lastPathComponent)
            }
            try await api.copyOut(id: id, source: path, destination: dest)
            if localPath.hasSuffix("/"), !isDir.boolValue {
                var resultIsDir: ObjCBool = false
                if fm.fileExists(atPath: dest, isDirectory: &resultIsDir), !resultIsDir.boolValue {
                    try? fm.removeItem(atPath: dest)
                    throw MicropodError.message("destination is not a directory: \(localPath)")
                }
            }
        case (.local(let localPath), .container(let id, let path)):
            let src = URL(fileURLWithPath: localPath).standardizedFileURL.path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src, isDirectory: &isDir) else {
                throw MicropodError.message("source path does not exist: \(localPath)")
            }
            if localPath.hasSuffix("/"), !isDir.boolValue {
                throw MicropodError.message("source path is not a directory: \(localPath)")
            }
            try await api.copyIn(id: id, source: src, destination: path)
        case (.container, .container):
            throw MicropodError.message("copying between containers is not supported")
        case (.local, .local):
            throw MicropodError.message("one of source or destination must be a container path")
        }
    }

    // MARK: - Cache-clone volumes

    private static func labelMap(_ specs: [LabelSpec]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: specs.map { ($0.key, $0.value) })
    }

    /// Per-container clone root: `~/Library/Application Support/
    /// micropod/volume-clones/<containerID>/<volume>.img`.
    /// `MICROPOD_VOLUME_CLONE_ROOT` overrides the root (tests/ops).
    public static var cloneRoot: URL {
        if let override = ProcessInfo.processInfo.environment["MICROPOD_VOLUME_CLONE_ROOT"],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("micropod/volume-clones", isDirectory: true)
    }

    /// APFS copy-on-write clone of a volume's backing image. `COPYFILE_CLONE`
    /// falls back to a regular copy on non-APFS volumes.
    public static func cloneVolumeImage(source: String, containerID: String, volume: String) throws -> String {
        let dir = cloneRoot.appendingPathComponent(containerID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("\(volume).img")
        try? FileManager.default.removeItem(at: dst)
        guard copyfile(source, dst.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
            throw MicropodError.message(
                "failed to clone volume '\(volume)' (\(source)): \(String(cString: strerror(errno)))")
        }
        return dst.path
    }

    static func removeClones(containerID: String) {
        try? FileManager.default.removeItem(
            at: cloneRoot.appendingPathComponent(containerID, isDirectory: true))
    }

    private func listEntries() async -> [ContainerListEntry] {
        (try? MicropodJSON.decodeArray(
            ContainerListEntry.self, from: await api.list(),
            context: "container list")) ?? []
    }

    /// Removes clone dirs whose container no longer exists. Called on
    /// cloning creates and prune so clone storage can't leak when a
    /// container is deleted outside this service. Dirs younger than 60s
    /// are skipped — they may belong to an in-flight create that hasn't
    /// reached `containerCreate` yet, so they aren't yet in `live`.
    private static let orphanGrace: TimeInterval = 60

    private func sweepOrphanClones(live: Set<String>) {
        let cutoff = Date().addingTimeInterval(-Self.orphanGrace)
        for dir
            in (try? FileManager.default.contentsOfDirectory(
                at: Self.cloneRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey])) ?? []
        where !live.contains(dir.lastPathComponent)
            && (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && ((try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                < cutoff
        {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Cloning a golden that a running container still has attached RW
    /// yields a crash-consistent clone (like an unfrozen disk snapshot) —
    /// usually mountable after journal replay, but worth telling the user
    /// so goldens are quiesced before use.
    private func warnIfGoldensInUse(_ cloneSet: Set<String>, entries: [ContainerListEntry]) {
        let wildcard = cloneSet.contains("*")
        for entry in entries where entry.status.state == "running" {
            for mount in entry.configuration.mounts ?? [] {
                guard mount.typeName == "volume",
                    !(mount.options ?? []).contains("ro"),
                    case .object(let fields)? = mount.type?["volume"],
                    case .string(let name) = fields["name"],
                    wildcard || cloneSet.contains(name)
                else { continue }
                let notice =
                    "micropod: golden volume '\(name)' is attached read-write to running "
                    + "container '\(entry.id)' — clone is crash-consistent; quiesce or "
                    + "stop it for a clean snapshot\n"
                FileHandle.standardError.write(Data(notice.utf8))
            }
        }
    }

    private static func setNonblocking(_ handle: FileHandle) {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// One read on a nonblocking fd: `Data` on success (empty = EOF),
    /// nil when nothing is ready (EAGAIN) or the read fails.
    /// Raw `read(2)` keeps EAGAIN and EOF unambiguous — Foundation's
    /// `read(upToCount:)` can't be trusted to distinguish them.
    private static func readSome(_ handle: FileHandle) -> Data? {
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        let n = read(handle.fileDescriptor, &buf, buf.count)
        guard n >= 0 else { return nil }
        return Data(buf[0..<n])
    }
}
