import Darwin
import Foundation
import MicropodCore

/// Where the shared hvf machine keeps its assets, disk, runtime state and
/// logs. One root holds one machine; `MICROPOD_HVF_ROOT` overrides the
/// default `~/.micropod/hvf`.
///
/// ```
/// <root>/micropod-vmm        Hypervisor.framework VMM (hypervisor entitlement)
/// <root>/Image               arm64 Linux kernel
/// <root>/mp-hvf-init.cpio    guest init initramfs
/// <root>/tools/              guest tool bundle, shared read-only as `oci-tools`
/// <root>/disk.ext4           writable machine disk
/// <root>/machine.json        HVFMachineConfig
/// <root>/run/docker.sock     the guest Docker Engine API
/// <root>/run/buildkit.sock   the guest BuildKit daemon (bundles that ship it)
/// <root>/run/supervisor.lock held (flock) by the one live supervisor
/// <root>/run/start.lock      serialises clients that launch a supervisor
/// <root>/run/install.lock    held by `machine install` for its whole run
/// <root>/run/state.json      HVFMachineState, written by the supervisor
/// <root>/run/containers.json HVFContainerIndex: the machine's container ids
///                            and names, so routing works while it is stopped
/// <root>/run/guest-config/   host-owned files for the guest, shared as
///                            `mp-config` (mounted read-only by guest init at
///                            /run/micropod/host-config)
/// <root>/run/guest-config/cache-policy.json
///                            the cache policy (machine.json `cache`), rendered
/// <root>/logs/console.log    micropod-vmm stdout/stderr (guest console)
/// <root>/logs/supervisor.log the detached supervisor's own output
/// ```
public struct HVFMachineLayout: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(root: Self.defaultRoot(environment: environment))
    }

    public static func defaultRoot(environment: [String: String]) -> URL {
        if let configured = environment["MICROPOD_HVF_ROOT"], !configured.isEmpty {
            return URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".micropod/hvf")
    }

    public var vmm: URL { root.appendingPathComponent("micropod-vmm") }
    public var kernel: URL { root.appendingPathComponent("Image") }
    public var initrd: URL { root.appendingPathComponent("mp-hvf-init.cpio") }
    public var tools: URL { root.appendingPathComponent("tools") }
    public var disk: URL { root.appendingPathComponent("disk.ext4") }
    public var config: URL { root.appendingPathComponent("machine.json") }
    public var runDirectory: URL { root.appendingPathComponent("run") }
    public var dockerSocket: URL { runDirectory.appendingPathComponent("docker.sock") }
    public var buildkitSocket: URL { runDirectory.appendingPathComponent("buildkit.sock") }
    public var supervisorLock: URL { runDirectory.appendingPathComponent("supervisor.lock") }
    public var startLock: URL { runDirectory.appendingPathComponent("start.lock") }
    public var installLock: URL { runDirectory.appendingPathComponent("install.lock") }
    public var state: URL { runDirectory.appendingPathComponent("state.json") }
    public var containerIndex: URL { runDirectory.appendingPathComponent("containers.json") }
    var containerIndexLock: URL { runDirectory.appendingPathComponent("containers.lock") }
    /// Host-owned configuration the guest reads, shared as `mp-config`.
    public var guestConfigDirectory: URL { runDirectory.appendingPathComponent("guest-config") }
    /// The rendered `HVFMachineCachePolicy` the guest engine re-reads.
    public var cachePolicyFile: URL { guestConfigDirectory.appendingPathComponent(HVFMachineCachePolicy.fileName) }
    /// The tool bundle's build manifest (`ci/build-runner-tools.sh`).
    public var toolsManifest: URL { tools.appendingPathComponent(HVFToolsManifest.path) }
    public var logsDirectory: URL { root.appendingPathComponent("logs") }
    public var consoleLog: URL { logsDirectory.appendingPathComponent("console.log") }
    public var supervisorLog: URL { logsDirectory.appendingPathComponent("supervisor.log") }

    public var dockerEndpoint: String { "unix://" + dockerSocket.path }
    /// A BuildKit address for `docker buildx create --driver remote` or
    /// `buildctl --addr`; served only when the tool bundle ships BuildKit.
    public var buildkitEndpoint: String { "unix://" + buildkitSocket.path }

    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, NUL included.
    public static let maxSocketPathBytes = 103

    /// What a tool bundle needs for the guest to serve BuildKit on its
    /// vsock port 2377: the guest engine starts `runner/bin/buildkitd` with
    /// `runner/buildkitd.toml` on the first connection, and serves nothing
    /// there without them.
    public static let buildkitBundleFiles = ["runner/bin/buildkitd", "runner/buildkitd.toml"]

    /// The BuildKit files missing from the installed tool bundle (`tools/`);
    /// empty when it ships BuildKit.
    public func missingBuildKitFiles(fileManager: FileManager = .default) -> [String] {
        Self.missingBuildKitFiles(inBundle: tools, fileManager: fileManager)
    }

    /// Same, for a bundle directory anywhere.
    public static func missingBuildKitFiles(inBundle bundle: URL, fileManager: FileManager = .default) -> [String] {
        let daemon = bundle.appendingPathComponent(buildkitBundleFiles[0])
        let config = bundle.appendingPathComponent(buildkitBundleFiles[1])
        var missing: [String] = []
        if !isRegularFile(daemon) || !fileManager.isExecutableFile(atPath: daemon.path) {
            missing.append(buildkitBundleFiles[0])
        }
        if !isRegularFile(config) { missing.append(buildkitBundleFiles[1]) }
        return missing
    }

    /// The installed pieces the machine cannot boot without, by layout name.
    public func missingAssets(fileManager: FileManager = .default) -> [String] {
        var missing: [String] = []
        for (name, url) in [("micropod-vmm", vmm), ("Image", kernel), ("mp-hvf-init.cpio", initrd)]
        where !Self.isRegularFile(url) {
            missing.append(name)
        }
        if !Self.isRegularFile(disk) { missing.append("disk.ext4") }
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: tools.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            missing.append("tools/")
        } else if !fileManager.fileExists(atPath: tools.appendingPathComponent("runner/start.sh").path) {
            missing.append("tools/runner/start.sh")
        }
        return missing
    }

    /// Why the layout cannot host a machine even when every asset is present.
    public func configurationProblem(fileManager: FileManager = .default) -> String? {
        if Self.isRegularFile(vmm), !fileManager.isExecutableFile(atPath: vmm.path) {
            return "\(vmm.path) is not executable"
        }
        do {
            try validatePaths()
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    /// True while `micropod machine install` runs against this root: no
    /// supervisor may start until it finishes.
    public var installInProgress: Bool { HVFFileLock.isHeld(installLock) }

    public func installInProgressError() -> MicropodError {
        .message(
            "unavailable: the hvf machine under \(root.path) is being installed; "
                + "start it once `micropod machine install` finishes")
    }

    /// Unix socket path lengths, and paths the VMM parses as `a:b[:ro]`.
    public func validatePaths() throws {
        for socket in [dockerSocket.path, buildkitSocket.path] where socket.utf8.count > Self.maxSocketPathBytes {
            throw MicropodError.message(
                "invalidArgument: hvf socket path \(socket) is \(socket.utf8.count) bytes; unix sockets allow "
                    + "\(Self.maxSocketPathBytes). Use a shorter MICROPOD_HVF_ROOT")
        }
        // Every share and socket spec is built from a path under the root.
        try Self.validateSpecPath(root.path, what: "machine root")
    }

    /// micropod-vmm splits `--share tag:path[:ro]` on every colon.
    static func validateSpecPath(_ path: String, what: String) throws {
        guard !path.contains(":") else {
            throw MicropodError.message("invalidArgument: hvf \(what) path must not contain ':': \(path)")
        }
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// `realpath(3)`, or the standardized path when it does not resolve:
    /// the kernel reports `/private/tmp/...` for a root spelled `/tmp/...`.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - Configuration

/// `<root>/machine.json`. Missing keys take their defaults so a hand-edited
/// file stays valid; an unknown schema is refused rather than guessed at.
public struct HVFMachineConfig: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int
    public var cpus: Int
    public var memoryMiB: Int
    /// Absolute host directory shared read-write and mounted at the same
    /// path in the guest (`--workspace`): Docker bind mounts resolve only
    /// under it. Defaults to the home directory; nil (saved as "") turns
    /// host bind mounts off.
    public var workspace: String?
    /// The VMM's published-port network (`--published-net`).
    public var publishedNet: Bool
    /// Echo the guest serial console into `logs/console.log` (no `--quiet`).
    public var console: Bool
    /// SIGTERM → orderly guest poweroff budget (`--shutdown-timeout`, 1...600).
    public var shutdownTimeoutSeconds: Int
    /// Appended to the VMM's kernel command line (`--cmdline-append`).
    public var kernelArguments: [String]
    /// Extra micropod-vmm flags, appended verbatim.
    public var extraArguments: [String]
    /// The dependency-cache policy; nil (absent from the file) means the
    /// defaults. Edited by `micropod machine cache policy`.
    public var cache: HVFMachineCachePolicy?

    public static var defaultWorkspace: String { HVFMachineLayout.canonicalPath(NSHomeDirectory()) }

    enum CodingKeys: String, CodingKey {
        case schema, cpus, memoryMiB, workspace, publishedNet, console, shutdownTimeoutSeconds, kernelArguments
        case extraArguments, cache
    }

    public init(
        schema: Int = HVFMachineConfig.currentSchema, cpus: Int = 4, memoryMiB: Int = 4096,
        workspace: String? = HVFMachineConfig.defaultWorkspace, publishedNet: Bool = true, console: Bool = true,
        shutdownTimeoutSeconds: Int = 10, kernelArguments: [String] = [], extraArguments: [String] = [],
        cache: HVFMachineCachePolicy? = nil
    ) {
        self.schema = schema
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.workspace = workspace
        self.publishedNet = publishedNet
        self.console = console
        self.shutdownTimeoutSeconds = shutdownTimeoutSeconds
        self.kernelArguments = kernelArguments
        self.extraArguments = extraArguments
        self.cache = cache
    }

    public init(from decoder: any Decoder) throws {
        let defaults = HVFMachineConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? defaults.schema
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? defaults.cpus
        memoryMiB = try c.decodeIfPresent(Int.self, forKey: .memoryMiB) ?? defaults.memoryMiB
        // Absent → the default share; "" → deliberately none.
        let workspace = try c.decodeIfPresent(String.self, forKey: .workspace) ?? defaults.workspace
        self.workspace = workspace?.isEmpty == true ? nil : workspace
        publishedNet = try c.decodeIfPresent(Bool.self, forKey: .publishedNet) ?? defaults.publishedNet
        console = try c.decodeIfPresent(Bool.self, forKey: .console) ?? defaults.console
        shutdownTimeoutSeconds =
            try c.decodeIfPresent(Int.self, forKey: .shutdownTimeoutSeconds) ?? defaults.shutdownTimeoutSeconds
        kernelArguments = try c.decodeIfPresent([String].self, forKey: .kernelArguments) ?? []
        extraArguments = try c.decodeIfPresent([String].self, forKey: .extraArguments) ?? []
        cache = try c.decodeIfPresent(HVFMachineCachePolicy.self, forKey: .cache)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(cpus, forKey: .cpus)
        try c.encode(memoryMiB, forKey: .memoryMiB)
        try c.encode(workspace ?? "", forKey: .workspace)
        try c.encode(publishedNet, forKey: .publishedNet)
        try c.encode(console, forKey: .console)
        try c.encode(shutdownTimeoutSeconds, forKey: .shutdownTimeoutSeconds)
        try c.encode(kernelArguments, forKey: .kernelArguments)
        try c.encode(extraArguments, forKey: .extraArguments)
        try c.encodeIfPresent(cache, forKey: .cache)
    }

    /// `cache`, or the defaults when machine.json has none.
    public var effectiveCachePolicy: HVFMachineCachePolicy { cache ?? HVFMachineCachePolicy() }

    /// The saved config, or the defaults when `url` does not exist.
    public static func load(from url: URL) throws -> HVFMachineConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return HVFMachineConfig()
        }
        let config: HVFMachineConfig
        do {
            config = try JSONDecoder().decode(HVFMachineConfig.self, from: data)
        } catch {
            throw MicropodError.message("invalidArgument: \(url.path) is not a valid hvf machine config: \(error)")
        }
        try config.validate()
        return config
    }

    public func save(to url: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try HVFFiles.writeAtomically(try encoder.encode(self), to: url)
    }

    public func validate() throws {
        guard schema == Self.currentSchema else {
            throw MicropodError.message(
                "failedPrecondition: hvf machine config schema \(schema) is not supported (want \(Self.currentSchema))")
        }
        guard (1...64).contains(cpus) else {
            throw MicropodError.message("invalidArgument: hvf cpus must be 1...64, got \(cpus)")
        }
        guard (512...262_144).contains(memoryMiB) else {
            throw MicropodError.message("invalidArgument: hvf memoryMiB must be 512...262144, got \(memoryMiB)")
        }
        guard (1...600).contains(shutdownTimeoutSeconds) else {
            throw MicropodError.message(
                "invalidArgument: hvf shutdownTimeoutSeconds must be 1...600, got \(shutdownTimeoutSeconds)")
        }
        if let workspace {
            // Lexical, like the VMM's own check. (Foundation's standardizing
            // would also strip a real `/private` prefix.)
            let components = workspace.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            guard workspace.hasPrefix("/"), workspace != "/",
                !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            else {
                throw MicropodError.message(
                    "invalidArgument: hvf workspace must be a canonical absolute directory, got '\(workspace)'")
            }
            try HVFMachineLayout.validateSpecPath(workspace, what: "workspace")
        }
        try cache?.validate()
    }

    /// How long the supervisor waits after SIGTERM before SIGKILL: past the
    /// VMM's own poweroff budget, so an orderly stop is never cut short.
    public var stopGrace: Duration { .seconds(shutdownTimeoutSeconds + 5) }
}

// MARK: - VMM command line

public enum HVFVMMCommand {
    /// Guest vsock port of the Docker Engine API (`vmm/guest-init`).
    public static let dockerGuestPort = 2375
    /// Guest vsock port guest init bridges to the engine's BuildKit socket.
    /// Exposed whatever the bundle: without BuildKit in it the guest closes
    /// each connection (see `HVFMachineLayout.missingBuildKitFiles`).
    public static let buildkitGuestPort = 2377
    /// The virtiofs tag of `HVFMachineLayout.guestConfigDirectory`. Shared
    /// writable on the VMM side: micropod-vmm treats a `:ro` share as
    /// immutable and never shows the guest a file the host replaced. Guest
    /// init mounts it read-only.
    public static let configShareTag = "mp-config"
    /// Tells guest init to mount `configShareTag` at /run/micropod/host-config.
    public static let configBootArgument = "mp.config=1"

    /// The full micropod-vmm argv (without the executable) for `config`.
    public static func arguments(layout: HVFMachineLayout, config: HVFMachineConfig, parentPID: Int32) throws
        -> [String]
    {
        try config.validate()
        try layout.validatePaths()
        var args = [
            "--kernel", layout.kernel.path,
            "--initrd", layout.initrd.path,
            "--disk", layout.disk.path,
            "--share", "oci-tools:\(layout.tools.path):ro",
            "--share", "\(configShareTag):\(layout.guestConfigDirectory.path)",
        ]
        // The VMM adds the share and the guest boot argument itself.
        if let workspace = config.workspace { args += ["--workspace", workspace] }
        args += ["--vsock-expose", "\(layout.dockerSocket.path):\(dockerGuestPort)"]
        args += ["--vsock-expose", "\(layout.buildkitSocket.path):\(buildkitGuestPort)"]
        if config.publishedNet { args.append("--published-net") }
        args += ["--cpus", String(config.cpus), "--memory-mib", String(config.memoryMiB)]
        // Before the configured arguments, so one of them can still override it.
        args += ["--cmdline-append", configBootArgument]
        for argument in config.kernelArguments { args += ["--cmdline-append", argument] }
        if !config.console { args.append("--quiet") }
        args += [
            "--shutdown-timeout", String(config.shutdownTimeoutSeconds), "--json-summary",
            "--parent-pid", String(parentPID),
        ]
        return args + config.extraArguments
    }
}

// MARK: - Supervisor state

public enum HVFMachinePhase: String, Codable, Sendable, Equatable {
    case starting, running, stopping, stopped, failed
}

/// `<root>/run/state.json`, replaced atomically by the supervisor on every
/// transition. Readers combine it with the supervisor lock: a `running`
/// record whose supervisor no longer holds the lock is stale.
public struct HVFMachineState: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int
    public var phase: HVFMachinePhase
    public var supervisorPID: Int32
    /// The supervisor's process start time (seconds), so `stop` never
    /// signals a recycled pid.
    public var supervisorStartSeconds: Int64?
    public var vmmPID: Int32?
    public var vmmStartSeconds: Int64?
    /// When the current (or last) VMM was launched.
    public var startedAt: Date?
    public var readyAt: Date?
    /// VMM relaunches after unexpected exits, this supervisor lifetime.
    public var restartCount: Int
    public var lastExitReason: String?
    /// The last VMM exit status and what micropod-vmm defines it to mean
    /// (nil after a signal or a failed launch).
    public var lastExitCode: Int32?
    public var lastExitMeaning: String?
    public var updatedAt: Date

    public init(
        phase: HVFMachinePhase, supervisorPID: Int32, supervisorStartSeconds: Int64? = nil, vmmPID: Int32? = nil,
        vmmStartSeconds: Int64? = nil, startedAt: Date? = nil, readyAt: Date? = nil, restartCount: Int = 0,
        lastExitReason: String? = nil, lastExitCode: Int32? = nil, lastExitMeaning: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.lastExitCode = lastExitCode
        self.lastExitMeaning = lastExitMeaning
        schema = Self.currentSchema
        self.phase = phase
        self.supervisorPID = supervisorPID
        self.supervisorStartSeconds = supervisorStartSeconds
        self.vmmPID = vmmPID
        self.vmmStartSeconds = vmmStartSeconds
        self.startedAt = startedAt
        self.readyAt = readyAt
        self.restartCount = restartCount
        self.lastExitReason = lastExitReason
        self.updatedAt = updatedAt
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// nil when no supervisor has written state yet.
    public static func load(from url: URL) throws -> HVFMachineState? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        do {
            return try decoder.decode(HVFMachineState.self, from: data)
        } catch {
            throw MicropodError.message("internal: unreadable hvf machine state \(url.path): \(error)")
        }
    }

    public func save(to url: URL) throws {
        try HVFFiles.writeAtomically(try Self.encoder.encode(self), to: url)
    }
}

// MARK: - File helpers

enum HVFFiles {
    /// Temporary file + fsync + rename, so a reader sees the old or the new
    /// contents and never a torn write.
    static func writeAtomically(_ data: Data, to url: URL, mode: mode_t = 0o644) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw posixError("create \(temporary.path)") }
        var closed = false
        defer {
            if !closed { close(fd) }
            unlink(temporary.path)
        }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw posixError("write \(temporary.path)") }
                offset += n
            }
        }
        guard fsync(fd) == 0 else { throw posixError("fsync \(temporary.path)") }
        closed = true
        guard close(fd) == 0 else { throw posixError("close \(temporary.path)") }
        guard rename(temporary.path, url.path) == 0 else { throw posixError("rename to \(url.path)") }
    }

    /// Writes all of `data` to `fd`, retrying `EINTR`; any other failure
    /// (ENOSPC, EIO, EPIPE, EBADF) drops the rest. Never raises: unlike
    /// `FileHandle.write(_:)` it cannot abort a long-lived process whose
    /// log destination broke. False when not everything was written.
    @discardableResult
    static func writeBestEffort(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    static func posixError(_ what: String, _ code: Int32 = errno) -> MicropodError {
        .message("internal: hvf: \(what): \(String(cString: strerror(code)))")
    }
}
