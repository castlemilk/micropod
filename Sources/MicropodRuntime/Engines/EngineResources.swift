import Foundation
import MicropodCore

// MARK: - Engine-side volume and image stores

/// Named volumes kept by an engine other than the Apple runtime (whose
/// volume service each surface passes to `VolumeRouter` itself). Calls the
/// engine cannot honour throw `.unsupported`.
public protocol EngineVolumeServing: Sendable {
    func list() async throws -> [Micropod_V1_Volume]
    /// `labels` and `options` are `key=value` strings, as the CLI takes them.
    func create(name: String, size: String?, labels: [String], options: [String]) async throws
    func delete(_ name: String) async throws
    func prune() async throws -> String
    /// Cheap ownership test for by-name routing. Never boots anything.
    func owns(_ name: String) async -> Bool
}

/// Images kept by an engine other than the Apple runtime.
public protocol EngineImageServing: Sendable {
    func list() async throws -> [Micropod_V1_Image]
    func pull(_ reference: String, platform: String?) -> AsyncThrowingStream<ProgressEvent, Error>
    func delete(_ reference: String, force: Bool) async throws
    func tag(source: String, target: String) async throws
    func inspect(_ reference: String) async throws -> Data
    func prune(danglingOnly: Bool) async throws -> String
    /// Cheap ownership test for by-reference routing. Never boots anything.
    func owns(_ reference: String) async -> Bool
    /// The store implements `save` and `load` (a Docker image archive).
    var savesAndLoads: Bool { get }
    /// Writes `references` as one Docker image archive (`docker save`) to
    /// `outputPath`, replacing a file already there.
    func save(_ references: [String], to outputPath: String) async throws
    /// Loads a Docker or OCI image archive (`docker load`); returns what
    /// the engine reported.
    func load(from inputPath: String) async throws -> String
}

extension EngineImageServing {
    public var savesAndLoads: Bool { false }

    public func save(_ references: [String], to outputPath: String) async throws {
        throw MicropodError.unsupported("this runtime does not support image save")
    }

    public func load(from inputPath: String) async throws -> String {
        throw MicropodError.unsupported("this runtime does not support image load")
    }
}

// MARK: - Docker Engine API

/// Volume and image calls on a Docker Engine API. Shared by the docker
/// engine (every call) and the hvf engine (the calls its guest implements).
enum DockerResources {
    static func escape(_ value: String) -> String { DockerEngine.escape(value) }

    /// An image reference in a path keeps its slashes, as Docker's own
    /// clients send it (`/images/docker.io/library/alpine:3.20/json`).
    static func escapeReference(_ reference: String) -> String {
        reference.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? reference
    }

    /// `["a=1", "b"]` → `["a": "1", "b": ""]`.
    static func keyValues(_ pairs: [String]) -> [String: String] {
        Dictionary(
            pairs.map { pair in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
            }, uniquingKeysWith: { $1 })
    }

    // MARK: Volumes

    static func volume(from entry: [String: Any]) -> Micropod_V1_Volume {
        Micropod_V1_Volume.with {
            $0.id = entry["Name"] as? String ?? ""
            $0.driver = entry["Driver"] as? String ?? ""
            $0.source = entry["Mountpoint"] as? String ?? ""
            $0.createdAt = entry["CreatedAt"] as? String ?? ""
            $0.labels = entry["Labels"] as? [String: String] ?? [:]
            // Only `system df` reports volume sizes; a listing has none.
            if let usage = entry["UsageData"] as? [String: Any], let size = usage["Size"] as? Int, size > 0 {
                $0.sizeBytes = UInt64(size)
            }
        }
    }

    static func listVolumes(_ docker: DockerClient) async throws -> [Micropod_V1_Volume] {
        let response = try docker.check(try await docker.request("GET", "/volumes"))
        let body = try response.json() as? [String: Any]
        return (body?["Volumes"] as? [[String: Any]] ?? []).map(volume(from:))
    }

    static func createVolume(_ docker: DockerClient, name: String, labels: [String], options: [String]) async throws {
        var body: [String: Any] = ["Name": name, "Labels": keyValues(labels)]
        if !options.isEmpty { body["DriverOpts"] = keyValues(options) }
        try docker.check(try await docker.request("POST", "/volumes/create", json: body))
    }

    /// 409 is a volume some container still mounts.
    static func deleteVolume(_ docker: DockerClient, _ name: String) async throws {
        let response = try await docker.request("DELETE", "/volumes/\(escape(name))")
        if response.status == 409 {
            throw MicropodError.message("failedPrecondition: volume '\(name)' is in use: \(response.message)")
        }
        try docker.check(response)
    }

    static func volumeExists(_ docker: DockerClient, _ name: String) async -> Bool {
        guard docker.reachable,
            let response = try? await docker.request("GET", "/volumes/\(escape(name))", timeout: .seconds(3))
        else { return false }
        return response.status == 200
    }

    /// Every unused volume, named ones included (`all`), like Apple's prune.
    static func pruneVolumes(_ docker: DockerClient) async throws -> String {
        let response = try docker.check(
            try await docker.request("POST", "/volumes/prune", query: ["filters": #"{"all":["true"]}"#]))
        let body = try response.json() as? [String: Any]
        let removed = (body?["VolumesDeleted"] as? [String])?.count ?? 0
        let bytes = body?["SpaceReclaimed"] as? Int ?? 0
        return "removed \(removed) volumes, reclaimed \(bytes) bytes"
    }

    // MARK: Images

    static func image(from entry: [String: Any]) -> Micropod_V1_Image {
        Micropod_V1_Image.with { image in
            image.id = entry["Id"] as? String ?? ""
            image.names = (entry["RepoTags"] as? [String] ?? []).filter { $0 != "<none>:<none>" }
            if let digest = (entry["RepoDigests"] as? [String])?.first?.split(separator: "@").last {
                image.digest = String(digest)
            }
            if let created = entry["Created"] as? Double, created > 0 {
                image.createdAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: created))
            } else if let created = entry["Created"] as? String {
                image.createdAt = created
            }
            if let size = entry["Size"] as? Int, size > 0 { image.sizeBytes = UInt64(size) }
            let os = entry["Os"] as? String ?? ""
            let architecture = entry["Architecture"] as? String ?? ""
            if !os.isEmpty || !architecture.isEmpty {
                image.variants = [
                    Micropod_V1_ImageVariant.with {
                        $0.os = os
                        $0.architecture = architecture
                        $0.variant = entry["Variant"] as? String ?? ""
                    }
                ]
            }
        }
    }

    static func listImages(_ docker: DockerClient) async throws -> [Micropod_V1_Image] {
        let response = try docker.check(try await docker.request("GET", "/images/json"))
        return (try response.json() as? [[String: Any]] ?? []).map(image(from:))
    }

    static func inspectImage(_ docker: DockerClient, _ reference: String) async throws -> Data {
        try docker.check(try await docker.request("GET", "/images/\(escapeReference(reference))/json")).body
    }

    static func imageExists(_ docker: DockerClient, _ reference: String) async -> Bool {
        guard docker.reachable,
            let response = try? await docker.request(
                "GET", "/images/\(escapeReference(reference))/json", timeout: .seconds(3))
        else { return false }
        return response.status == 200
    }

    static func deleteImage(_ docker: DockerClient, _ reference: String, force: Bool) async throws {
        let response = try await docker.request(
            "DELETE", "/images/\(escapeReference(reference))", query: force ? ["force": "1"] : [:])
        if response.status == 409 {
            throw MicropodError.message("failedPrecondition: image '\(reference)' is in use: \(response.message)")
        }
        try docker.check(response)
    }

    /// `target` is `repo[:tag]`; a registry port is not mistaken for a tag.
    static func tagImage(_ docker: DockerClient, source: String, target: String) async throws {
        let (repo, tag) = splitTag(target)
        var query = ["repo": repo]
        if let tag { query["tag"] = tag }
        try docker.check(try await docker.request("POST", "/images/\(escapeReference(source))/tag", query: query))
    }

    /// `GET /images/{ref}/get`, or `/images/get?names=…` for several,
    /// streamed into a temporary file beside `outputPath` that then
    /// replaces it: a failed save leaves no partial archive behind.
    static func saveImages(_ docker: DockerClient, _ references: [String], to outputPath: String) async throws {
        guard !references.isEmpty else { throw MicropodError.message("invalidArgument: save needs an image") }
        let destination = URL(fileURLWithPath: NSString(string: outputPath).expandingTildeInPath)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).micropod-save-\(UUID().uuidString)")
        let path: String
        if references.count == 1 {
            path = "/images/\(escapeReference(references[0]))/get"
        } else {
            var query = URLComponents()
            query.queryItems = references.map { URLQueryItem(name: "names", value: $0) }
            path = "/images/get?" + (query.percentEncodedQuery ?? "")
        }
        try await docker.download("GET", path, to: temporary)
        guard rename(temporary.path, destination.path) == 0 else {
            let failure = Socket.posix("rename to \(destination.path)")
            unlink(temporary.path)
            throw failure
        }
    }

    /// `POST /images/load` with the archive as the body. The reply is a
    /// JSON object (or a stream of them) whose `stream`/`error` fields say
    /// what happened.
    static func loadImages(_ docker: DockerClient, from inputPath: String) async throws -> String {
        let source = URL(fileURLWithPath: NSString(string: inputPath).expandingTildeInPath)
        let response = try docker.check(
            try await docker.upload(
                "POST", "/images/load", query: ["quiet": "1"], from: source, contentType: "application/x-tar"))
        var lines: [String] = []
        for line in String(decoding: response.body, as: UTF8.self).split(separator: "\n") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                lines.append(String(line))
                continue
            }
            if let error = object["error"] as? String { throw MicropodError.message("internal: docker: \(error)") }
            if let stream = object["stream"] as? String {
                lines += stream.split(separator: "\n").map(String.init)
            }
        }
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func splitTag(_ reference: String) -> (repo: String, tag: String?) {
        let name = reference.split(separator: "@", maxSplits: 1).first.map(String.init) ?? reference
        guard let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") else { return (name, nil) }
        return (String(name[..<colon]), String(name[name.index(after: colon)...]))
    }

    static func pruneImages(_ docker: DockerClient, danglingOnly: Bool) async throws -> String {
        let filters = danglingOnly ? #"{"dangling":["true"]}"# : #"{"dangling":["false"]}"#
        let response = try docker.check(try await docker.request("POST", "/images/prune", query: ["filters": filters]))
        let body = try response.json() as? [String: Any]
        let removed = (body?["ImagesDeleted"] as? [[String: Any]])?.count ?? 0
        let bytes = body?["SpaceReclaimed"] as? Int ?? 0
        return "removed \(removed) images, reclaimed \(bytes) bytes"
    }

    /// `POST /images/create`: one progress event per JSON line. Docker
    /// reports a failed pull inside a 200 stream (`{"error": …}`), so every
    /// line is checked; a non-2xx status throws with the engine's message.
    static func pull(_ docker: DockerClient, _ reference: String, platform: String?)
        -> AsyncThrowingStream<ProgressEvent, Error>
    {
        var query = ["fromImage": reference]
        if let platform, !platform.isEmpty { query["platform"] = platform }
        let chunks = docker.stream("POST", "/images/create", query: query)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var lines = PullLineSplitter()
                do {
                    for try await chunk in chunks {
                        for line in lines.feed(chunk) { continuation.yield(try progress(line)) }
                    }
                    if let last = lines.flush() { continuation.yield(try progress(last)) }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `{"status": "Downloading", "progress": "[==>  ] 1MB/3MB", "id": "abc"}`
    /// → one line; `{"error": …}` throws.
    static func progress(_ line: String) throws -> ProgressEvent {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return ProgressEvent(line: line)
        }
        if let error = (object["errorDetail"] as? [String: Any])?["message"] as? String ?? object["error"] as? String {
            throw MicropodError.message("internal: docker: pull failed: \(error)")
        }
        let parts = [object["id"] as? String, object["status"] as? String, object["progress"] as? String]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
        return ProgressEvent(line: parts.joined(separator: " "))
    }
}

/// Newline-delimited JSON across arbitrary chunk boundaries.
struct PullLineSplitter {
    private var buffer = Data()

    mutating func feed(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    mutating func flush() -> String? {
        defer { buffer.removeAll() }
        let rest = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }
}

// MARK: - Docker engine stores

/// A Docker Engine's named volumes. Size is not a local-driver option, so
/// `--size` is refused rather than dropped.
struct DockerVolumeStore: EngineVolumeServing {
    let engine: DockerEngine

    func list() async throws -> [Micropod_V1_Volume] { try await DockerResources.listVolumes(try engine.api()) }

    func create(name: String, size: String?, labels: [String], options: [String]) async throws {
        if size != nil {
            throw MicropodError.unsupported(
                "runtime '\(engine.name)' does not support a volume size (the local driver has none); use --opt instead"
            )
        }
        try await DockerResources.createVolume(try engine.api(), name: name, labels: labels, options: options)
    }

    func delete(_ name: String) async throws { try await DockerResources.deleteVolume(try engine.api(), name) }
    func prune() async throws -> String { try await DockerResources.pruneVolumes(try engine.api()) }

    func owns(_ name: String) async -> Bool {
        guard let client = engine.client else { return false }
        return await DockerResources.volumeExists(client, name)
    }
}

/// A Docker Engine's images. Push needs the registry credentials Docker's
/// own CLI holds, so it stays with `docker push`.
struct DockerImageStore: EngineImageServing {
    let engine: DockerEngine

    func list() async throws -> [Micropod_V1_Image] { try await DockerResources.listImages(try engine.api()) }

    func pull(_ reference: String, platform: String?) -> AsyncThrowingStream<ProgressEvent, Error> {
        do {
            return DockerResources.pull(try engine.api(), reference, platform: platform)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    func delete(_ reference: String, force: Bool) async throws {
        try await DockerResources.deleteImage(try engine.api(), reference, force: force)
    }

    func tag(source: String, target: String) async throws {
        try await DockerResources.tagImage(try engine.api(), source: source, target: target)
    }

    func inspect(_ reference: String) async throws -> Data {
        try await DockerResources.inspectImage(try engine.api(), reference)
    }

    func prune(danglingOnly: Bool) async throws -> String {
        try await DockerResources.pruneImages(try engine.api(), danglingOnly: danglingOnly)
    }

    func owns(_ reference: String) async -> Bool {
        guard let client = engine.client else { return false }
        return await DockerResources.imageExists(client, reference)
    }
}
