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
///                            (the four above: the legacy flat payload)
/// <root>/versions/<id>/      immutable payloads with the same four assets
///                            (`HVFPayloadStore`); `current`, `staged`,
///                            `known-good`, `previous` and `trial` name them
/// <root>/update.lock         held by every payload stage/activate/rollback/prune
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
    private let dockerSocketOverride: URL?

    public init(root: URL, dockerSocketOverride: URL? = nil) {
        self.root = root.standardizedFileURL
        self.dockerSocketOverride = dockerSocketOverride?.standardizedFileURL
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(root: Self.defaultRoot(environment: environment))
    }

    public static func defaultRoot(environment: [String: String]) -> URL {
        if let configured = environment["MICROPOD_HVF_ROOT"], !configured.isEmpty {
            return URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
        }
        return standardRoot(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The machine a plain `micropod` uses: `<home>/.micropod/hvf`, whatever
    /// `MICROPOD_HVF_ROOT` says.
    public static func standardRoot(home: URL) -> URL {
        home.appendingPathComponent(".micropod/hvf")
    }

    /// This is the standard machine (`~/.micropod/hvf`, symlinks resolved),
    /// not a throwaway root that `MICROPOD_HVF_ROOT` names.
    public func isStandardRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        func resolved(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        return resolved(root) == resolved(Self.standardRoot(home: home))
    }

    /// Immutable payload directories (`HVFPayloadStore`).
    public var versionsDirectory: URL { root.appendingPathComponent("versions") }
    /// The payload a newly started supervisor boots. Only an activation that
    /// passed the health probes, or a rollback, moves it; staging never does.
    public var currentLink: URL { root.appendingPathComponent("current") }
    /// What `current` named before the last activation or rollback.
    public var previousLink: URL { root.appendingPathComponent("previous") }
    /// The newest staged payload, waiting for an activation.
    public var stagedLink: URL { root.appendingPathComponent("staged") }
    /// The last payload that booted and passed the health probes: what a
    /// rollback returns to. Never pruned.
    public var knownGoodLink: URL { root.appendingPathComponent("known-good") }
    /// The payload an activation is booting to probe it. Honoured only while
    /// `updateLock` is held, so one left by a killed activator boots nothing.
    public var trialLink: URL { root.appendingPathComponent("trial") }
    /// Held (flock) across every stage, activation, rollback and prune.
    public var updateLock: URL { root.appendingPathComponent("update.lock") }
    /// Why the last activation of the staged payload failed.
    public var activationFailureRecord: URL { root.appendingPathComponent("activation-failure.json") }

    /// The payload a supervisor started now would boot, resolved once: the
    /// trial of a live activation, else `current`, else the legacy flat
    /// layout (the root itself). Every asset of one launch comes from the one
    /// directory this returns, so a launch can never mix two versions.
    public func resolvePayload() -> HVFMachinePayload {
        if HVFFileLock.isHeld(updateLock), let trial = HVFPayloadStore.resolveVersion(trialLink, in: self) {
            return HVFMachinePayload(directory: trial, isVersioned: true)
        }
        if let current = HVFPayloadStore.resolveVersion(currentLink, in: self) {
            return HVFMachinePayload(directory: current, isVersioned: true)
        }
        return HVFMachinePayload(directory: root, isVersioned: false)
    }

    /// The directory `resolvePayload()` names.
    public var activePayloadRoot: URL { resolvePayload().directory }

    // One asset each: a caller that needs several resolves the payload once.
    public var vmm: URL { resolvePayload().vmm }
    public var kernel: URL { resolvePayload().kernel }
    public var initrd: URL { resolvePayload().initrd }
    public var tools: URL { resolvePayload().tools }
    public var disk: URL { root.appendingPathComponent("disk.ext4") }
    /// Optional persistent second VirtioBlk disk (`/dev/vdb` -> `/var/lib/micropod/caches`)
    /// so dependency caches survive `disk.ext4` OS replacements. BuildKit's state
    /// (`RUN --mount=type=cache` included) stays on `disk.ext4` with the containerd
    /// snapshots it refers to, so a replaced OS disk starts it empty and consistent.
    public var cacheDisk: URL { root.appendingPathComponent("caches.ext4") }
    public var config: URL { root.appendingPathComponent("machine.json") }
    public var runDirectory: URL { root.appendingPathComponent("run") }
    public var dockerSocket: URL { dockerSocketOverride ?? runDirectory.appendingPathComponent("docker.sock") }
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

    /// Canonical `~/.micropod/docker.sock` symlink path that exposes the HVF
    /// Docker Engine v1.47 socket to zero-config Docker/Testcontainers clients.
    public static func canonicalDockerSocket(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicit = environment["MICROPOD_DOCKER_SOCK"], !explicit.isEmpty {
            return URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".micropod/docker.sock")
    }

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
        let payload = resolvePayload()
        var missing: [String] = []
        for (name, url) in [
            ("micropod-vmm", payload.vmm), ("Image", payload.kernel), ("mp-hvf-init.cpio", payload.initrd),
        ]
        where !Self.isRegularFile(url) {
            missing.append(name)
        }
        if !Self.isRegularFile(disk) { missing.append("disk.ext4") }
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: payload.tools.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            missing.append("tools/")
        } else if !fileManager.fileExists(atPath: payload.tools.appendingPathComponent("runner/start.sh").path) {
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
        // A machine.json that does not load or validate (a control port in
        // allowHostPorts, a goProxy that is not a URL) keeps the supervisor
        // from starting: say so, never show the defaults as the config.
        do {
            _ = try HVFMachineConfig.load(from: config)
        } catch {
            let message = error.localizedDescription
            return message.contains(config.path) ? message : "\(config.path): \(message)"
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
    public static func canonicalPath(_ path: String) -> String {
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
    /// Host loopback TCP ports reachable from inside the guest via `10.42.0.1:<port>`
    /// (`host.micropod.internal:<port>`). Passed as `--allow-host-port` to `micropod-vmm`;
    /// every container in the machine reaches them as a local client. Micropod's
    /// control ports are refused (`HVFHostPortAllowlist.controlPorts`).
    public var allowHostPorts: [UInt16]
    /// The rig dependency proxy's host port: opened to the guest when, and
    /// only when, the cache policy's `goProxy` or `npmRegistry` names it at
    /// the gateway. 0 lets no policy URL open a port.
    public var depproxyPort: UInt16
    /// The dependency-cache policy; nil (absent from the file) means the
    /// defaults. Edited by `micropod machine cache policy`.
    public var cache: HVFMachineCachePolicy?
    /// The size of the persistent cache disk (`caches.ext4`) `machine
    /// install` found or created: every boot expects that disk, and the
    /// install, the supervisor and `machine status` say so when it is gone.
    /// nil: no cache disk, the stores live on the OS disk.
    public var cacheDiskBytes: UInt64?

    public static var defaultWorkspace: String { HVFMachineLayout.canonicalPath(NSHomeDirectory()) }
    /// Cuttlefish's depproxy listens on host loopback 7677.
    public static let defaultDepproxyPort: UInt16 = 7677

    enum CodingKeys: String, CodingKey {
        case schema, cpus, memoryMiB, workspace, publishedNet, console, shutdownTimeoutSeconds, kernelArguments
        case extraArguments, allowHostPorts, depproxyPort, cache
        case cacheDiskBytes
    }

    public init(
        schema: Int = HVFMachineConfig.currentSchema, cpus: Int = 4, memoryMiB: Int = 4096,
        workspace: String? = HVFMachineConfig.defaultWorkspace, publishedNet: Bool = true, console: Bool = true,
        shutdownTimeoutSeconds: Int = 10, kernelArguments: [String] = [], extraArguments: [String] = [],
        allowHostPorts: [UInt16] = [], depproxyPort: UInt16 = HVFMachineConfig.defaultDepproxyPort,
        cache: HVFMachineCachePolicy? = nil, cacheDiskBytes: UInt64? = nil
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
        self.allowHostPorts = allowHostPorts
        self.depproxyPort = depproxyPort
        self.cache = cache
        self.cacheDiskBytes = cacheDiskBytes
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
        allowHostPorts = try c.decodeIfPresent([UInt16].self, forKey: .allowHostPorts) ?? []
        depproxyPort = try c.decodeIfPresent(UInt16.self, forKey: .depproxyPort) ?? defaults.depproxyPort
        cache = try c.decodeIfPresent(HVFMachineCachePolicy.self, forKey: .cache)
        cacheDiskBytes = try c.decodeIfPresent(UInt64.self, forKey: .cacheDiskBytes)
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
        if !allowHostPorts.isEmpty { try c.encode(allowHostPorts, forKey: .allowHostPorts) }
        if depproxyPort != Self.defaultDepproxyPort { try c.encode(depproxyPort, forKey: .depproxyPort) }
        try c.encodeIfPresent(cache, forKey: .cache)
        try c.encodeIfPresent(cacheDiskBytes, forKey: .cacheDiskBytes)
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
        let control = HVFHostPortAllowlist.controlPorts()
        for port in allowHostPorts {
            guard port >= HVFHostPortAllowlist.minimumPolicyPort else {
                throw MicropodError.message(
                    "invalidArgument: hvf allowHostPorts entries must be \(HVFHostPortAllowlist.minimumPolicyPort)"
                        + "...65535, got \(port): ports below it are privileged host services (sshd, CUPS, SMB)")
            }
            guard !control.contains(port) else {
                throw MicropodError.message(
                    "invalidArgument: hvf allowHostPorts must not include \(port): it is a Micropod control port, "
                        + "and every container in the machine would reach it as a local client")
            }
        }
        // The VMM opens host ports only through allowHostPorts and the
        // policy: an extra argument would bypass the control-port denylist
        // and never show in `machine status`.
        if let flag = extraArguments.first(where: { $0 == "--allow-host-port" || $0.hasPrefix("--allow-host-port=") }) {
            throw MicropodError.message(
                "invalidArgument: hvf extraArguments must not contain \(flag): list host ports in allowHostPorts, "
                    + "which refuses Micropod's control ports")
        }
        if depproxyPort != 0 {
            guard depproxyPort >= HVFHostPortAllowlist.minimumPolicyPort, !control.contains(depproxyPort) else {
                throw MicropodError.message(
                    "invalidArgument: hvf depproxyPort must be 0 or \(HVFHostPortAllowlist.minimumPolicyPort)...65535 "
                        + "and not a Micropod control port, got \(depproxyPort)")
            }
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
    /// Tells guest init a persistent cache disk (`caches.ext4`) is attached as
    /// `/dev/vdb`: when it is then missing or does not mount, the guest turns
    /// shared caches off for the boot instead of creating stores on the OS
    /// disk below the mount point.
    public static let cacheDiskBootArgument = "mp.cache_disk=1"
    /// Keeps the guest kernel's informational boot messages off its serial
    /// console: notices, warnings and errors still print, and everything
    /// stays in the kernel's log buffer. Each byte on the PL011 console is a
    /// trapped register write; the ~16 KB the kernel prints at boot cost
    /// every boot, and so every payload switchover, ~30 ms. A configured
    /// `loglevel=` (machine.json `kernelArguments`) comes later and wins.
    public static let kernelLogLevelBootArgument = "loglevel=6"
    /// Names the machine root for guest init (`mp.private_b64`, base64 with a
    /// trailing "." as micropod-vmm writes `mp.workspace_b64`) when it lies
    /// inside the workspace share, as the standard machine's `~/.micropod/hvf`
    /// does in the default home-directory workspace. The guest engine then
    /// refuses a bind source inside it and hides it in a bind that covers it,
    /// so no container reaches machine.json, the disks or the host-owned cache
    /// policy through the workspace.
    public static func privateRootBootArgument(root: URL, workspace: String?) -> String? {
        guard let workspace, !workspace.isEmpty else { return nil }
        let rootPath = HVFMachineLayout.canonicalPath(root.path)
        let share = HVFMachineLayout.canonicalPath(workspace)
        guard share == "/" || rootPath == share || rootPath.hasPrefix(share + "/") else { return nil }
        return "mp.private_b64=\(Data(rootPath.utf8).base64EncodedString())."
    }

    /// The full micropod-vmm argv (without the executable) for `config`,
    /// booting `payload` (default: `layout.resolvePayload()`, resolved once).
    public static func arguments(
        layout: HVFMachineLayout, payload: HVFMachinePayload? = nil, config: HVFMachineConfig, parentPID: Int32
    ) throws -> [String] {
        try config.validate()
        try layout.validatePaths()
        let payload = payload ?? layout.resolvePayload()
        var args = [
            "--kernel", payload.kernel.path,
            "--initrd", payload.initrd.path,
            "--disk", layout.disk.path,
        ]
        let cacheDisk = HVFMachineLayout.isRegularFile(layout.cacheDisk)
        if cacheDisk {
            args += ["--cache-disk", layout.cacheDisk.path]
        }
        args += [
            "--share", "oci-tools:\(payload.tools.path):ro",
            "--share", "\(configShareTag):\(layout.guestConfigDirectory.path)",
        ]
        // The VMM adds the share and the guest boot argument itself.
        if let workspace = config.workspace { args += ["--workspace", workspace] }
        args += ["--vsock-expose", "\(layout.dockerSocket.path):\(dockerGuestPort)"]
        args += ["--vsock-expose", "\(layout.buildkitSocket.path):\(buildkitGuestPort)"]
        if config.publishedNet { args.append("--published-net") }
        for port in effectiveAllowHostPorts(config) {
            args += ["--allow-host-port", String(port)]
        }
        args += ["--cpus", String(config.cpus), "--memory-mib", String(config.memoryMiB)]
        // Before the configured arguments, so one of them can still override it.
        args += ["--cmdline-append", configBootArgument]
        if cacheDisk { args += ["--cmdline-append", cacheDiskBootArgument] }
        if let privateRoot = privateRootBootArgument(root: layout.root, workspace: config.workspace) {
            args += ["--cmdline-append", privateRoot]
        }
        args += ["--cmdline-append", kernelLogLevelBootArgument]
        for argument in config.kernelArguments { args += ["--cmdline-append", argument] }
        if !config.console { args.append("--quiet") }
        args += [
            "--shutdown-timeout", String(config.shutdownTimeoutSeconds), "--json-summary",
            "--parent-pid", String(parentPID),
        ]
        return args + config.extraArguments
    }

    /// The `--allow-host-port` list, sorted: `config.allowHostPorts`, plus
    /// `config.depproxyPort` while the cache policy names it at the gateway
    /// (`http://10.42.0.1:7677/go|direct`). No other policy URL opens a
    /// port, and no control port is ever opened; see `HVFHostPortAllowlist`.
    public static func effectiveAllowHostPorts(
        _ config: HVFMachineConfig, controlPorts: Set<UInt16> = HVFHostPortAllowlist.controlPorts()
    ) -> [UInt16] {
        HVFHostPortAllowlist(config: config, controlPorts: controlPorts).ports
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
    /// Immutable payload directory and manifest version loaded by the active VMM.
    public var loadedPayloadPath: String?
    public var loadedPayloadVersion: String?
    public var loadedPayloadRevision: String?
    /// The host ports (`--allow-host-port`) the current (or last) VMM was
    /// launched with; nil from a supervisor that predates the record.
    public var allowHostPorts: [UInt16]?
    public var updatedAt: Date

    public init(
        phase: HVFMachinePhase, supervisorPID: Int32, supervisorStartSeconds: Int64? = nil, vmmPID: Int32? = nil,
        vmmStartSeconds: Int64? = nil, startedAt: Date? = nil, readyAt: Date? = nil, restartCount: Int = 0,
        lastExitReason: String? = nil, lastExitCode: Int32? = nil, lastExitMeaning: String? = nil,
        loadedPayloadPath: String? = nil, loadedPayloadVersion: String? = nil, loadedPayloadRevision: String? = nil,
        allowHostPorts: [UInt16]? = nil, updatedAt: Date = Date()
    ) {
        self.allowHostPorts = allowHostPorts
        self.lastExitCode = lastExitCode
        self.lastExitMeaning = lastExitMeaning
        self.loadedPayloadPath = loadedPayloadPath
        self.loadedPayloadVersion = loadedPayloadVersion
        self.loadedPayloadRevision = loadedPayloadRevision
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
