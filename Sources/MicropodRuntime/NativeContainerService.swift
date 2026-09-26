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
    /// Exit codes of containers this service started. `run`/`start`
    /// register a `containerWait` waiter *before* `startProcess` (the
    /// runtime helper replays a cached status to pre-registered waiters),
    /// so even a container that exits within milliseconds gets a real code.
    private let exitCodes: ExitCodeRegistry

    public init(
        api: APIServerClient, cli: ContainerService,
        images: ImagesServiceClient = ImagesServiceClient(),
        policy: @escaping @Sendable () -> VolumePolicy = { VolumePolicyStore.load() },
        exitCodes: ExitCodeRegistry = ExitCodeRegistry()
    ) {
        self.api = api
        self.cli = cli
        self.images = images
        self.policy = policy
        self.exitCodes = exitCodes
    }

    public func list() async throws -> [Micropod_V1_Container] {
        try await entries().map(ModelMapper.container(from:))
    }

    public func inspect(_ id: String) async throws -> Data {
        guard let data = try await api.get(id: id) else {
            throw Self.containerNotFound(id)
        }
        return data
    }

    /// What `inspect` throws for an id the runtime does not list: coded
    /// `notFound:` like the apiserver's own errors, so the one
    /// classification table (`ConnectCodeMapping`) reads it as `not_found`
    /// wherever it surfaces — the docker shim's `/wait` among them.
    static func containerNotFound(_ id: String) -> MicropodError {
        VolumeClone.notFound("container \(id) not found")
    }

    public func create(_ request: ContainerRunRequest) async throws -> String {
        if request.tty || request.interactive {
            // TTY/interactive needs a real pty wired through ProcessIO —
            // keep the CLI path for those.
            return try await cli.create(request)
        }
        let id = try await createNative(request)
        await UnstartedCreates.shared.record(id)
        return id
    }

    public func run(_ request: ContainerRunRequest) async throws -> String {
        if request.tty || request.interactive || !request.detach {
            // Interactive/TTY needs a pty; non-detached runs attach and
            // stream output — both are ProcessIO concerns the CLI owns.
            return try await cli.run(request)
        }
        let id = try await createNative(request)
        do {
            try await startTracked(id, createdHere: true)
        } catch {
            // Match the CLI: a failed start cleans up the created container.
            // Under the id's create mutex, so a replayed create of this id
            // waits for the cleanup and then finds neither container nor
            // clone dir, instead of having a clone it just placed unlinked.
            await InFlightCreates.shared.withExclusive(id) {
                try? await api.delete(id: id, force: true)
                await VolumeClone.removeClones(containerID: id)
            }
            throw error
        }
        return id
    }

    /// bootstrap boots the VM and waits for vminitd; the init process is
    /// only started by containerStartProcess with processId == id — that's
    /// also what flips the apiserver's status to `running`. The exit-code
    /// waiter is registered in between so the helper already has it when
    /// the process starts (and exits, however quickly). A `notFound` from
    /// either call is looked into (`startLookingIntoNotFound`); `createdHere`
    /// says this process created the container, which is what lets the
    /// error say it was deleted. The three steps run as one attempt under the
    /// process-wide ``StartGate``, one start at a time.
    private func startTracked(_ id: String, createdHere: Bool) async throws {
        try await Self.startLookingIntoNotFound(
            id: id,
            createdHere: createdHere,
            gate: .shared,
            bootstrap: { try await api.bootstrap(id: id) },
            startProcess: {
                await exitCodes.track(id: id) { [api] in
                    try await api.waitProcess(containerId: id, processId: id)
                }
                do {
                    try await api.startProcess(containerId: id, processId: id)
                } catch {
                    await exitCodes.forget(id: id)
                    throw error
                }
            },
            exists: { try await api.get(id: id) != nil })
    }

    /// Waits between start attempts that answered `notFound` while the
    /// runtime still listed the container (see `startLookingIntoNotFound`).
    static let startNotFoundBackoff: [Duration] = [.milliseconds(50), .milliseconds(150), .milliseconds(400)]

    /// A start — `bootstrap`, then `startProcess` (which registers the
    /// exit-code waiter and calls `containerStartProcess`) — looking into a
    /// `notFound` from either call.
    ///
    /// container-apiserver answers `notFound: container with ID <id> not
    /// found` to bootstrap, startProcess and wait only when the id is missing
    /// from its container table; `containerCreate` fills that table under the
    /// service lock before it replies, and a delete of that id empties it. A
    /// created container stays `stopped` until startProcess runs, so a plain
    /// delete (or a prune) can take it between bootstrap and startProcess —
    /// the live defect-4 start failed there: its bootstrap succeeded and
    /// `containerStartProcess` and the waiter's `containerWait` answered
    /// `notFound`. The apiserver keeps no tombstones, so the answer is the
    /// same for an id that never existed. So the container is looked up
    /// again:
    ///  - not listed: the start fails `not_found` at once, logged — a real
    ///    deletion is never retried or masked. The error says the container
    ///    was deleted before it could start only when `createdHere` (this
    ///    process created it); otherwise it says only that the runtime does
    ///    not list it;
    ///  - still listed (the id was deleted and created again in between): the
    ///    whole start is retried after each `backoff` step — bootstrap is a
    ///    no-op for a bootstrapped container — each retry logged; when the
    ///    steps run out the last `notFound` stands.
    /// Any other error, and a `notFound` whose lookup fails, is thrown as it
    /// came.
    ///
    /// Each attempt — bootstrap and startProcess together — holds `gate`, so
    /// concurrent starts reach the apiserver's FIFO lock as bootstrap,
    /// startProcess, bootstrap, … instead of every bootstrap first
    /// (``StartGate``). The lookup and the backoff run outside it. A start
    /// cancelled while it waits for the gate throws `CancellationError`
    /// without calling either.
    static func startLookingIntoNotFound(
        id: String,
        createdHere: Bool,
        backoff: [Duration] = startNotFoundBackoff,
        gate: StartGate = .shared,
        bootstrap: () async throws -> Void,
        startProcess: () async throws -> Void,
        exists: () async throws -> Bool,
        log: (String) -> Void = { FileHandle.standardError.write(Data("micropod: \($0)\n".utf8)) }
    ) async throws {
        var retries = 0
        while true {
            var call = "bootstrap"
            do {
                try await gate.withExclusive {
                    try await bootstrap()
                    call = "startProcess"
                    try await startProcess()
                }
                return
            } catch {
                guard ConnectCodeMapping.code(for: error) == "not_found" else { throw error }
                let listed: Bool
                do {
                    listed = try await exists()
                } catch let lookup {
                    log(
                        "start \(id): \(call) answered not found and the lookup failed "
                            + "(\(lookup.localizedDescription))")
                    throw error
                }
                guard listed else {
                    if createdHere {
                        log(
                            "start \(id): \(call) answered not found and the runtime no longer lists the container "
                                + "this process created: it was deleted before it could start")
                        throw MicropodError.message(
                            "notFound: container with ID \(id) not found: "
                                + "it was created, then deleted before it could start")
                    }
                    log("start \(id): \(call) answered not found and the runtime does not list the container")
                    throw MicropodError.message(
                        "notFound: container with ID \(id) not found: the runtime does not list it")
                }
                guard retries < backoff.count else {
                    log("start \(id): \(call) still answers not found after \(retries) retries; giving up")
                    throw error
                }
                let wait = backoff[retries]
                retries += 1
                log(
                    "start \(id): \(call) answered not found but the runtime still lists the container; "
                        + "retrying the start in \(wait) (\(retries)/\(backoff.count))")
                try await Task.sleep(for: wait)
            }
        }
    }

    /// Native `container create`: resolve image → build
    /// `ContainerConfiguration` → `containerCreate` XPC.
    ///
    /// The whole create — list check, orphan sweep, stale-dir reclaim,
    /// clone placement, `containerCreate` and the failure cleanup — runs
    /// under the id's in-process create mutex (`InFlightCreates`), so two
    /// creates of the same id never overlap: this create is the sole placer
    /// under `<cloneRoot>/<id>` for its whole duration. A replay of the same
    /// request waits for the winner; if the winner succeeded the replay's
    /// list check answers `already_exists` before it places or reclaims
    /// anything, and if the winner failed the replay finds the dir the
    /// loser cleaned and proceeds as a genuine create.
    ///
    /// A failed create removes exactly the clone images it placed. Anything
    /// else under this id — a clone of a container that exists, possibly its
    /// live block device — stays, whatever this create's failure was
    /// (`already_exists` from the list check, from the exclusive placement
    /// or from the apiserver, or anything else).
    ///
    /// The name and every named volume are clone-path components
    /// (`<cloneRoot>/<id>/<volume>.img`) that reach the clone-dir lifecycle
    /// — orphan sweep, stale-dir reclaim, placement, failure removal —
    /// before the runtime sees them, so the runtime's grammars are enforced
    /// first (`invalid_argument`, as the runtime itself would answer) — the
    /// container-id grammar for the name, the volume grammar (no
    /// 63-character cap) for the volumes — before the mutex and before any
    /// filesystem or XPC work.
    private func createNative(_ request: ContainerRunRequest) async throws -> String {
        if let name = request.name {
            try VolumeClone.requireSafeComponent(name, as: "container id")
        }
        for volume in VolumeAttachments.namedVolumes(in: request.volumes) {
            try VolumeClone.requireSafeVolumeName(volume, as: "volume name")
        }
        let id = request.name ?? UUID().uuidString.lowercased()
        return try await InFlightCreates.shared.withExclusive(id) {
            var placed: [String] = []
            do {
                return try await createNativeInner(request, id: id, placed: &placed)
            } catch {
                await VolumeClone.removeClones(containerID: id, volumes: placed)
                throw error
            }
        }
    }

    /// Runs under the id's create mutex (see `createNative`). `placed`
    /// receives the name of every clone volume this create placed, as it
    /// places it, so the caller can remove exactly those on failure.
    private func createNativeInner(
        _ request: ContainerRunRequest, id: String, placed: inout [String]
    ) async throws -> String {
        let sysConfig = NativeConfigBuilder.loadSystemConfig()
        let platform = try NativeConfigBuilder.ociPlatform(request.platform)

        // Image resolution (ClientImage.fetch): local match or pull —
        // or, under `no_pull`, `not_found` naming the missing platform.
        let imageDescription = try await images.ensure(
            reference: request.image,
            platform: platform,
            registryDomain: sysConfig.registryDomain,
            noPull: request.noPull
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
        let parsedMounts = try NativeConfigBuilder.parseMounts(request: request)
        func isClone(_ name: String) -> Bool { cloneSet.contains(name) || cloneSet.contains("*") }
        let attachesDirectly = parsedMounts.contains { mount in
            if case .volume(let name, _, _) = mount { return !isClone(name) }
            return false
        }
        // One container list serves the duplicate-id check, the clone
        // pre-checks and the RW multi-attach guard; requests without named
        // volumes skip it. The list must succeed: an XPC failure is
        // `unavailable`, never an empty list that would wave the attach
        // through (or make every clone dir look orphaned).
        var volumeHolders = VolumeAttachments(entries: [])
        if !cloneSet.isEmpty || attachesDirectly {
            let entries = try await entries()
            // A duplicate id fails first: before any clone is written (the
            // clone dir is keyed by id, so cloning would overwrite the existing
            // container's images) and before the multi-attach guard, which
            // would otherwise refuse a replayed create by naming the container
            // it replays as the holder of its own volumes. Same error shape as
            // the apiserver's own check, which still runs for the no-volume path.
            if entries.contains(where: { $0.id == id }) {
                throw MicropodError.message("alreadyExists: container with ID \(id) already exists")
            }
            volumeHolders = VolumeAttachments(entries: entries)
            if !cloneSet.isEmpty {
                // Self-heal: a clone dir orphaned by a raw `container delete`
                // (or a crashed runtime) is swept on the next cloning create.
                let live = Set(entries.map(\.id))
                await VolumeClone.sweepOrphanClones(live: live)
                // No container has this id (checked above) and, under the
                // id's create mutex, no other create in this process is
                // placing under it, so a clone dir here is the leftover of a
                // create that died with its process. Reclaimed whatever its
                // age — the retry must not be refused `already_exists` for a
                // container that never was.
                await VolumeClone.reclaimStaleCloneDir(containerID: id, live: live)
                warnIfGoldensInUse(cloneSet, entries: entries)
            }
        }
        var mounts: [JSONValue] = []
        for mount in parsedMounts {
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
                if isClone(name) {
                    let golden = try await Self.placeClone(volume: name, containerID: id) {
                        try await api.volumeInspect(name: name)
                    }
                    placed.append(name)
                    mounts.append(
                        NativeConfigBuilder.filesystemObject(
                            type: "block",
                            typeFields: [
                                "format": .string(golden.format),
                                "cache": .object([policy.cacheCase(labels: labelMap): .object([:])]),
                                "sync": .object([
                                    policy.syncCase(labels: labelMap, fallback: "nosync"):
                                        .object([:])
                                ]),
                            ],
                            source: golden.clone,
                            destination: destination, options: options))
                } else {
                    // A direct attach shares the golden's block image with
                    // whoever else has it: refuse while a running container
                    // holds it read-write (clone mounts above never touch the
                    // golden, so they are exempt). `getOrCreate` is idempotent,
                    // so checking after it costs nothing and also catches a
                    // holder that mounted the image by path.
                    let volume = try await api.getOrCreateVolume(name: name)
                    let source = NativeConfigBuilder.string(volume["source"]) ?? ""
                    try Self.requireNotHeld(name, source: source, holders: volumeHolders)
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
                            source: source,
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
        let createdHere = await UnstartedCreates.shared.contains(id)
        do {
            try await startTracked(id, createdHere: createdHere)
        } catch {
            await UnstartedCreates.shared.remove(id)
            throw error
        }
        await UnstartedCreates.shared.remove(id)
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
        let running = try await entries(status: "running")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for entry in running {
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
        await exitCodes.forget(id: id)
        await UnstartedCreates.shared.remove(id)
        await VolumeClone.removeClones(containerID: id)
    }

    public func deleteAll(force: Bool = false) async throws {
        let all = try await entries()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for entry in all {
                group.addTask {
                    try await self.api.delete(id: entry.id, force: force)
                    await self.exitCodes.forget(id: entry.id)
                    await UnstartedCreates.shared.remove(entry.id)
                    await VolumeClone.removeClones(containerID: entry.id)
                }
            }
            try await group.waitForAll()
        }
    }

    /// `container prune` — the CLI composes list(stopped) → diskUsage →
    /// delete; every route it uses is native here.
    public func prune() async throws -> String {
        let stopped = try await entries(status: "stopped")
        var pruned: [String] = []
        var totalSize: UInt64 = 0
        let now = Date()
        for entry in stopped where Self.isPrunable(entry, now: now) {
            do {
                totalSize += (try? await api.diskUsage(id: entry.id)) ?? 0
                try await api.delete(id: entry.id)
                await exitCodes.forget(id: entry.id)
                await UnstartedCreates.shared.remove(entry.id)
                await VolumeClone.removeClones(containerID: entry.id)
                pruned.append(entry.id)
            } catch {
                continue
            }
        }
        // Orphan sweep: clone dirs whose container is already gone (e.g.
        // deleted via the raw `container` CLI) would otherwise leak. Only
        // with the runtime's answer in hand — a failed list is not an empty
        // one, and sweeping against it would unlink live containers' clones.
        if let live = try? await entries() {
            await VolumeClone.sweepOrphanClones(live: Set(live.map(\.id)))
        }
        let freed = ByteCountFormatter().string(fromByteCount: Int64(totalSize))
        return pruned.joined(separator: "\n") + (pruned.isEmpty ? "" : "\nReclaimed \(freed) in disk space")
    }

    /// How long after its creation a never-started container is safe from
    /// `prune`: far longer than any client's create → start gap (the
    /// Connect `CreateContainer` → `StartContainer` pair, `docker run`, a
    /// compose project starting services in dependency order), short
    /// enough that an abandoned create goes with the next periodic prune.
    static let unstartedPruneGrace: TimeInterval = 300

    /// Whether `prune` may delete this stopped container. The runtime lists
    /// a container that was created and never started as `stopped`, exactly
    /// like one that ran and exited, until its startProcess runs; deleting
    /// it before then fails its client's start `not_found` — the live
    /// defect-4 signature, whatever issued that delete. So a container
    /// without a start date that was created within `unstartedPruneGrace` is
    /// kept. A container without a readable creation date has nothing
    /// proving it fresh and is prunable, as before.
    ///
    /// Only this native prune applies the grace: the CLI backend's `prune`
    /// runs `container prune`, which deletes every stopped container,
    /// never-started ones included.
    static func isPrunable(_ entry: ContainerListEntry, now: Date) -> Bool {
        if let started = entry.status.startedDate, !started.isEmpty { return true }
        guard let raw = entry.configuration.creationDate,
            let created = try? Date(raw, strategy: .iso8601)
        else { return true }
        return now.timeIntervalSince(created) >= unstartedPruneGrace
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
    /// micropod/volume-clones/<containerID>/<volume>.img`
    /// (`MICROPOD_VOLUME_CLONE_ROOT` overrides it) — see `VolumeClone`.
    public static var cloneRoot: URL { VolumeClone.cloneRoot }

    /// APFS copy-on-write clone of a volume's backing image at
    /// `cloneRoot/<containerID>/<volume>.img`; returns that path. Placed
    /// exclusively: the duplicate-id list check above is a snapshot, so a
    /// replayed create that lost the race may get here after the winner
    /// placed — and started writing — its clone. That clone is never renamed
    /// over; the loser fails `already_exists` and removes only what it
    /// placed itself.
    public static func cloneVolumeImage(source: String, containerID: String, volume: String) throws -> String {
        let destination = try VolumeClone.clonePath(containerID: containerID, volume: volume)
        try VolumeClone.cloneImage(from: source, to: destination.path, placement: .exclusive)
        return destination.path
    }

    /// Under `volume`'s lock — the one `DeleteVolume` and `volume prune`
    /// hold — reads the golden through `inspect` and places container
    /// `containerID`'s clone of it (`cloneVolumeImage`), so the golden
    /// cannot be removed between the inspect and the clonefile. Returns the
    /// clone's path and the golden's filesystem format.
    static func placeClone(
        volume name: String, containerID: String, inspect: () async throws -> JSONValue?
    ) async throws -> (clone: String, format: String) {
        try await VolumeLocks.shared.withLock(name) {
            guard let volume = try await inspect() else {
                throw MicropodError.message("cache clone source volume '\(name)' not found")
            }
            let format = NativeConfigBuilder.string(volume["format"]) ?? "ext4"
            let source = NativeConfigBuilder.string(volume["source"]) ?? ""
            guard !source.isEmpty else {
                throw MicropodError.message("cache clone source volume '\(name)' has no backing image")
            }
            return (try Self.cloneVolumeImage(source: source, containerID: containerID, volume: name), format)
        }
    }

    /// RW multi-attach guard (see `VolumeAttachments`): a `failedPrecondition:`
    /// naming volume and holder, or a warning when
    /// `MICROPOD_ALLOW_MULTI_ATTACH=1` restores the historic behaviour.
    private static func requireNotHeld(_ name: String, source: String, holders: VolumeAttachments) throws {
        guard let holder = holders.holder(of: name, source: source) else { return }
        let error = VolumeAttachments.inUseError(volume: name, holder: holder)
        guard VolumeAttachments.multiAttachAllowed() else { throw error }
        FileHandle.standardError.write(
            Data("micropod: \(error.localizedDescription) — attaching anyway (MICROPOD_ALLOW_MULTI_ATTACH=1)\n".utf8))
    }

    /// `containerList` as decoded entries. Throws like every other XPC call
    /// (a transport failure is `unavailable`): callers that guard on who
    /// holds what must fail closed rather than reason from an empty list.
    private func entries(status: String? = nil) async throws -> [ContainerListEntry] {
        try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: await api.list(status: status), context: "container list")
    }

    /// Cloning a golden that a running (or still stopping) container has
    /// attached RW yields a crash-consistent clone (like an unfrozen disk
    /// snapshot) — usually mountable after journal replay, but worth telling
    /// the user so goldens are quiesced before use.
    private func warnIfGoldensInUse(_ cloneSet: Set<String>, entries: [ContainerListEntry]) {
        let wildcard = cloneSet.contains("*")
        for entry in entries {
            guard let state = entry.status.state, VolumeAttachments.holdsVolumes(state: state) else { continue }
            for mount in entry.configuration.mounts ?? [] {
                guard mount.typeName == "volume",
                    !(mount.options ?? []).contains("ro"),
                    case .object(let fields)? = mount.type?["volume"],
                    case .string(let name) = fields["name"],
                    wildcard || cloneSet.contains(name)
                else { continue }
                let notice =
                    "micropod: golden volume '\(name)' is attached read-write to \(state) "
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
