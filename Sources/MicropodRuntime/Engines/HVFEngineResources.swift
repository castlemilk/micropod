import Foundation
import MicropodCore

/// The hvf machine's named volumes and images, over its guest Docker API.
///
/// Like containers, reads never boot the machine (a stopped machine lists
/// nothing and owns nothing); `create` and `pull` start it on demand. Only
/// what the guest engine implements is offered — verified against it by
/// `scripts/e2e_hvf.sh`:
///
/// | call | guest | here |
/// |---|---|---|
/// | `GET /volumes`, `GET /volumes/{name}` | 200 / 404 | list, inspect |
/// | `POST /volumes/create` (Name, Labels) | 201, idempotent | create |
/// | `POST /volumes/create` with DriverOpts | 400 | refused: no size or options |
/// | `DELETE /volumes/{name}` | 204 / 404 / 409 in use | delete |
/// | `POST /volumes/prune` | 404 | unsupported |
/// | `GET /images/json`, `GET /images/{ref}/json` | 200 / 404 (`Created` from the config) | list, inspect |
/// | `POST /images/create` (linux/arm64 in any spelling; another platform 400, an image without arm64 404) | 200, one status line | pull |
/// | `DELETE /images/{ref}` (tag: untag; ID or digest: remove) | 200 / 404 / 409 in use | delete |
/// | `POST /images/{ref}/tag` | 201 | tag |
/// | `/images/prune`, push | 501 | unsupported |
/// | `GET /images/{ref}/get`, `GET /images/get?names=…` | 200 tar (`ctr export`, linux/arm64) | save |
/// | `POST /images/load` | 200 `{"stream": …}` (`ctr import --local --digests`) | load |
/// | `GET /system/df` | 200, Docker's API 1.47 shape | not used here |
/// | `POST /build` | 501 (BuildKit has its own socket) | unsupported |
///
/// Save, load, removal and tagging need a guest that implements them
/// (bundles built from this tree); an older guest's 501 surfaces as the
/// error.
public struct HVFVolumeStore: EngineVolumeServing {
    let machine: HVFMachineClient

    private var docker: DockerClient { machine.docker }

    /// No guest round trip while the machine is down.
    private func requireServing(_ what: String) throws {
        guard machine.isServing else {
            throw MicropodError.message(
                "failedPrecondition: the hvf machine is not running (\(machine.status().summary)), so its "
                    + "\(what) cannot be reached; start it with `micropod machine start`")
        }
    }

    public func list() async throws -> [Micropod_V1_Volume] {
        guard machine.isServing else { return [] }
        return try await DockerResources.listVolumes(docker)
    }

    /// The guest's local driver takes a name and labels only.
    public func create(name: String, size: String?, labels: [String], options: [String]) async throws {
        if size != nil || !options.isEmpty {
            throw MicropodError.unsupported(
                "runtime 'hvf' does not support volume size or driver options (the guest engine's local driver "
                    + "takes a name and labels only)")
        }
        try await machine.ensureRunning()
        try await DockerResources.createVolume(docker, name: name, labels: labels, options: [])
    }

    public func delete(_ name: String) async throws {
        try requireServing("volume '\(name)'")
        try await DockerResources.deleteVolume(docker, name)
    }

    public func prune() async throws -> String {
        throw MicropodError.unsupported(
            "runtime 'hvf' does not support volume prune (the guest engine has no /volumes/prune); "
                + "remove volumes by name with `micropod volume rm --runtime hvf <name>`")
    }

    public func owns(_ name: String) async -> Bool {
        guard machine.isServing else { return false }
        return await DockerResources.volumeExists(docker, name)
    }
}

public struct HVFImageStore: EngineImageServing {
    let machine: HVFMachineClient

    private var docker: DockerClient { machine.docker }

    private func requireServing(_ what: String) throws {
        guard machine.isServing else {
            throw MicropodError.message(
                "failedPrecondition: the hvf machine is not running (\(machine.status().summary)), so its "
                    + "\(what) cannot be reached; start it with `micropod machine start`")
        }
    }

    static func unsupported(_ operation: String) -> MicropodError {
        .unsupported(
            "runtime 'hvf' does not support \(operation) (the guest engine answers 501: unsupported image operation)")
    }

    public func list() async throws -> [Micropod_V1_Image] {
        guard machine.isServing else { return [] }
        return try await DockerResources.listImages(docker)
    }

    /// Boots a stopped machine first, like `run`. The guest pulls
    /// linux/arm64 only and answers once the pull is done.
    public func pull(_ reference: String, platform: String?) -> AsyncThrowingStream<ProgressEvent, Error> {
        let machine = self.machine
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await machine.ensureRunning()
                    for try await event in DockerResources.pull(machine.docker, reference, platform: platform) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A tag is untagged; an ID or a digest removes the image once nothing
    /// uses it (409, as `failedPrecondition`, while a container does).
    public func delete(_ reference: String, force: Bool) async throws {
        try requireServing("image '\(reference)'")
        try await DockerResources.deleteImage(docker, reference, force: force)
    }

    public func tag(source: String, target: String) async throws {
        try requireServing("image '\(source)'")
        try await DockerResources.tagImage(docker, source: source, target: target)
    }

    public func prune(danglingOnly: Bool) async throws -> String { throw Self.unsupported("image prune") }

    public func inspect(_ reference: String) async throws -> Data {
        try requireServing("image '\(reference)'")
        return try await DockerResources.inspectImage(docker, reference)
    }

    public func owns(_ reference: String) async -> Bool {
        guard machine.isServing else { return false }
        return await DockerResources.imageExists(docker, reference)
    }

    public var savesAndLoads: Bool { true }

    /// The images must be on the running machine: a stopped one has none
    /// to save.
    public func save(_ references: [String], to outputPath: String) async throws {
        try requireServing("images (\(references.joined(separator: ", ")))")
        try await DockerResources.saveImages(docker, references, to: outputPath)
    }

    /// Boots a stopped machine first, like `pull`.
    public func load(from inputPath: String) async throws -> String {
        try await machine.ensureRunning()
        return try await DockerResources.loadImages(docker, from: inputPath)
    }
}
