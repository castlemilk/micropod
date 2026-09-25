import Foundation

public protocol ContainerServing: Sendable {
    func list() async throws -> [Micropod_V1_Container]
    func inspect(_ id: String) async throws -> Data
    /// Docker-style `create`: prepare the container without starting it.
    func create(_ request: ContainerRunRequest) async throws -> String
    func run(_ request: ContainerRunRequest) async throws -> String
    func exec(_ request: ContainerExecRequest) async throws -> String
    func start(_ id: String) async throws
    func stop(_ id: String, timeout: Int) async throws
    /// Docker-style restart: stop (with grace) then start.
    func restart(_ id: String) async throws
    func stopAll() async throws
    func kill(_ id: String, signal: String) async throws
    func delete(_ id: String, force: Bool) async throws
    func deleteAll(force: Bool) async throws
    /// Prunes stopped containers; returns the freed-space report text.
    func prune() async throws -> String
    func export(_ id: String, to outputPath: String) async throws
    func copy(from: String, to: String) async throws
}

/// Result of an exec, including the guest process exit code and stderr —
/// data the CLI path only surfaces as a thrown `cliFailure`.
public struct ContainerExecResult: Sendable, Equatable {
    public var output: String
    public var error: String
    public var exitCode: Int32

    public init(output: String, error: String, exitCode: Int32) {
        self.output = output
        self.error = error
        self.exitCode = exitCode
    }
}

extension ContainerServing {
    /// `exec` that reports the guest exit code instead of throwing on
    /// non-zero exits. CLI-backed implementations recover the code from the
    /// thrown `cliFailure`; native backends return it directly.
    public func execDetailed(_ request: ContainerExecRequest) async throws -> ContainerExecResult {
        do {
            return ContainerExecResult(output: try await exec(request), error: "", exitCode: 0)
        } catch MicropodError.cliFailure(let command, let code, let stderr) {
            return ContainerExecResult(
                output: "", error: "`\(command)` failed: \(stderr)", exitCode: code)
        }
    }

    /// Default-parameter shims so protocol-typed call sites keep working.
    public func stop(_ id: String) async throws {
        try await stop(id, timeout: 10)
    }

    public func kill(_ id: String) async throws {
        try await kill(id, signal: "KILL")
    }

    public func delete(_ id: String) async throws {
        try await delete(id, force: false)
    }

    /// Runtime state string for one container — `running`, `stopping`,
    /// `stopped`, `created` — read from the `inspect` JSON. `unknown` when
    /// the container is absent or the inspect fails; callers that need to
    /// distinguish "gone" from "not answering" must look the container up
    /// first. Never throws so poll loops can treat it as a plain observation.
    public func state(of id: String) async -> String {
        guard let data = try? await inspect(id),
            let entries = try? MicropodJSON.decodeArray(
                ContainerListEntry.self, from: data, context: "container inspect"),
            let entry = entries.first(where: { $0.id == id }) ?? entries.first
        else { return "unknown" }
        return entry.status.state ?? "unknown"
    }
}

public struct ContainerService: ContainerServing {
    private let client: ContainerCLIClient

    public init(client: ContainerCLIClient) {
        self.client = client
    }

    public func list() async throws -> [Micropod_V1_Container] {
        try await entries().map(ModelMapper.container(from:))
    }

    /// `container list --all --format json` as decoded entries — the mount
    /// detail (volume names, `ro`) that the curated proto model drops.
    public func entries() async throws -> [ContainerListEntry] {
        let output = try await client.run(ContainerCommandFactory.listContainers(all: true), timeout: .seconds(30))
        return try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: Data(output.utf8), context: "container list")
    }

    public func inspect(_ id: String) async throws -> Data {
        let output = try await client.run(ContainerCommandFactory.inspectContainers([id]), timeout: .seconds(15))
        return Data(output.utf8)
    }

    public func run(_ request: ContainerRunRequest) async throws -> String {
        try await refuseIfNoPullAndAbsent(request)
        try await refuseIfVolumeHeldElsewhere(request)
        let output = try await client.run(ContainerCommandFactory.run(request), timeout: .seconds(120))
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func create(_ request: ContainerRunRequest) async throws -> String {
        try await refuseIfNoPullAndAbsent(request)
        try await refuseIfVolumeHeldElsewhere(request)
        let output = try await client.run(ContainerCommandFactory.create(request), timeout: .seconds(120))
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// RW multi-attach guard: a named volume that a running or stopping
    /// container holds read-write is an ext4 image with a live writer (a
    /// stopping one is still flushing it) — attaching it again
    /// corrupts both views, and the runtime does not check. Refused with a
    /// `failedPrecondition:` naming volume and holder before the CLI is
    /// spawned; `MICROPOD_ALLOW_MULTI_ATTACH=1` downgrades that to a warning.
    /// Only requests that name a volume pay for the list.
    private func refuseIfVolumeHeldElsewhere(_ request: ContainerRunRequest) async throws {
        let names = VolumeAttachments.namedVolumes(in: request.volumes)
        guard !names.isEmpty else { return }
        let attachments = VolumeAttachments(entries: try await entries())
        for name in names {
            guard let holder = attachments.holder(of: name) else { continue }
            let error = VolumeAttachments.inUseError(volume: name, holder: holder)
            guard VolumeAttachments.multiAttachAllowed() else { throw error }
            FileHandle.standardError.write(
                Data(
                    "micropod: \(error.localizedDescription) — attaching anyway (MICROPOD_ALLOW_MULTI_ATTACH=1)\n".utf8)
            )
        }
    }

    /// `no_pull` on the CLI backend: `container create`/`run` pull a missing
    /// image implicitly (no timeout, no way to opt out), so the only honest
    /// refusal is a presence check *before* the CLI is spawned. The image
    /// must be stored under the requested tag/digest and, when the local
    /// copy advertises its variants, carry one for the requested platform
    /// (the CLI's default is `linux/<host arch>`, like `container run`).
    /// The `notFound:` prefix is what the Connect table maps to `not_found`.
    private func refuseIfNoPullAndAbsent(_ request: ContainerRunRequest) async throws {
        guard request.noPull else { return }
        let platform = try LocalImagePresence.platform(request.platform)
        let local = try await ImageService(client: client).list()
        guard LocalImagePresence.contains(request.image, platform: platform, in: local) else {
            throw MicropodError.message(
                "notFound: image \(request.image) not present locally for \(platform.os)/\(platform.architecture)")
        }
    }

    public func exec(_ request: ContainerExecRequest) async throws -> String {
        let output = try await client.run(ContainerCommandFactory.exec(request), timeout: .seconds(60))
        return output
    }

    public func start(_ id: String) async throws {
        _ = try await client.run(ContainerCommandFactory.startContainer(id), timeout: .seconds(60))
    }

    public func stop(_ id: String, timeout: Int = 10) async throws {
        _ = try await client.run(ContainerCommandFactory.stopContainer(id, timeout: timeout), timeout: .seconds(90))
    }

    public func restart(_ id: String) async throws {
        try await stop(id, timeout: 10)
        try await start(id)
    }

    public func stopAll() async throws {
        _ = try await client.run(ContainerCommandFactory.stopAllContainers(), timeout: .seconds(120))
    }

    public func kill(_ id: String, signal: String = "KILL") async throws {
        _ = try await client.run(
            ContainerCommandFactory.killContainer(id, signal: signal), timeout: .seconds(30))
    }

    public func delete(_ id: String, force: Bool = false) async throws {
        _ = try await client.run(ContainerCommandFactory.deleteContainer(id, force: force), timeout: .seconds(30))
    }

    public func deleteAll(force: Bool = false) async throws {
        _ = try await client.run(ContainerCommandFactory.deleteAllContainers(force: force), timeout: .seconds(120))
    }

    public func prune() async throws -> String {
        let output = try await client.run(ContainerCommandFactory.pruneContainers(), timeout: .seconds(60))
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func export(_ id: String, to outputPath: String) async throws {
        _ = try await client.run(ContainerCommandFactory.exportContainer(id, to: outputPath), timeout: .seconds(120))
    }

    public func copy(from: String, to: String) async throws {
        _ = try await client.run(ContainerCommandFactory.copyFile(from: from, to: to), timeout: .seconds(120))
    }
}

/// Presence check for `no_pull` on the CLI backend (see
/// `ContainerService.refuseIfNoPullAndAbsent`). Kept free of I/O so the
/// matching rules are testable against `image list` fixtures.
enum LocalImagePresence {
    struct Platform: Equatable {
        let os: String
        let architecture: String
    }

    /// `os/arch[/variant]` → normalised (os, arch); nil/empty means the CLI's
    /// default of `linux/<host arch>`. Malformed specs are `invalidArgument`.
    static func platform(_ raw: String?) throws -> Platform {
        guard let raw, !raw.isEmpty else {
            return Platform(os: "linux", architecture: hostArchitecture)
        }
        let parts = raw.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts.count <= 3, parts.allSatisfy({ !$0.isEmpty }) else {
            throw MicropodError.message("invalidArgument: platform '\(raw)' must be os/arch[/variant]")
        }
        return Platform(os: parts[0].lowercased(), architecture: normalizeArchitecture(parts[1]))
    }

    /// True when some local image is stored under `reference` (tag or digest
    /// form, via `localImageIsPresent`) and either advertises no platform
    /// information at all, or advertises a variant for `platform`.
    static func contains(_ reference: String, platform: Platform, in images: [Micropod_V1_Image]) -> Bool {
        images.contains { image in
            guard localImageIsPresent(reference, in: localImageReferenceInventory(from: [image])) else {
                return false
            }
            let advertised = image.variants.filter { !$0.os.isEmpty || !$0.architecture.isEmpty }
            guard !advertised.isEmpty else { return true }
            return advertised.contains {
                $0.os.lowercased() == platform.os
                    && normalizeArchitecture($0.architecture) == platform.architecture
            }
        }
    }

    /// OCI spellings the CLI and registries use interchangeably.
    static func normalizeArchitecture(_ raw: String) -> String {
        switch raw.lowercased() {
        case "aarch64", "arm64": return "arm64"
        case "x86_64", "x86-64", "amd64": return "amd64"
        default: return raw.lowercased()
        }
    }

    static var hostArchitecture: String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "amd64"
        #else
            return "unknown"
        #endif
    }
}
