import ContainerizationOCI
import Foundation
import MicropodCore

/// XPC routes for `com.apple.container.core.container-core-images` — the
/// plugin service backing `container image …` commands. Route names match
/// `ImagesServiceXPCRoute` in apple/container.
enum ImagesRoute: String {
    case imageList
    case imagePull
    case imageUnpack
    case snapshotGet
    case snapshotDelete
    case contentGet
}

/// A stored image resolved for one platform: the description a create
/// embeds as `ContainerConfiguration.image`, and that platform's OCI image
/// config (nil when the image's index does not list the platform).
public struct ResolvedImage: Sendable {
    public let description: JSONValue
    public let config: Image?
}

/// Client for the `container-core-images` XPC service: image listing,
/// pull-if-missing, and content-store reads used to resolve OCI image
/// configs for native `create`/`run`.
///
/// `contentGet` returns a *file path* into the local content store —
/// blobs are then read and decoded directly from disk.
public struct ImagesServiceClient: Sendable {
    public static let defaultService = "com.apple.container.core.container-core-images"

    /// One request/reply round trip: the XPC service's reply, or the error
    /// `XPCConnection.send` surfaces (`"<code>: <message>"` for the
    /// service's own failures).
    typealias Transport = @Sendable (XPCMessage, Duration?) async throws -> XPCMessage

    private let transport: Transport

    public init(service: String = ImagesServiceClient.defaultService) {
        let xpc = XPCConnection(service: service)
        self.transport = { request, timeout in try await xpc.send(request, responseTimeout: timeout) }
    }

    /// Test seam: scripted replies in place of the XPC service.
    init(transport: @escaping Transport) {
        self.transport = transport
    }

    private func send(_ request: XPCMessage, timeout: Duration? = nil) async throws -> XPCMessage {
        try await transport(request, timeout)
    }

    /// `imageList` → `[ImageDescription]` (`{reference, descriptor{…}}` objects).
    public func list() async throws -> [JSONValue] {
        let reply = try await send(.init(route: ImagesRoute.imageList.rawValue), timeout: .seconds(15))
        guard let data = reply.data(key: .imageDescriptions) else { return [] }
        return try MicropodJSON.decoder.decode([JSONValue].self, from: data)
    }

    /// `imagePull` — registry pull. Can take minutes for large images, so
    /// no response timeout (the CLI blocks for the whole pull too).
    @discardableResult
    public func pull(reference: String, platform: JSONValue?, insecure: Bool = false) async throws -> JSONValue {
        let request = XPCMessage(route: ImagesRoute.imagePull.rawValue)
        request.set(key: .imageReference, value: reference)
        request.set(key: .insecureFlag, value: insecure)
        request.set(key: .maxConcurrentDownloads, value: Int64(3))
        if let platform,
            let data = try? JSONEncoder().encode(platform)
        {
            request.set(key: .ociPlatform, value: data)
        }
        let reply = try await send(request)
        guard let data = reply.data(key: .imageDescription) else {
            throw MicropodError.message("imagePull returned no imageDescription")
        }
        return try MicropodJSON.decoder.decode(JSONValue.self, from: data)
    }

    /// `contentGet` → local content-store path for a digest.
    public func contentPath(digest: String) async throws -> String {
        let request = XPCMessage(route: ImagesRoute.contentGet.rawValue)
        request.set(key: .digest, value: digest)
        let reply = try await send(request, timeout: .seconds(30))
        guard let path = reply.string(key: .contentPath) else {
            throw MicropodError.message("content \(digest) not found")
        }
        return path
    }

    /// Read + decode a content-store blob by digest.
    public func content<T: Decodable>(_ type: T.Type, digest: String) async throws -> T {
        let path = try await contentPath(digest: digest)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: - High level resolution (ports ClientImage semantics)

    /// `ClientImage.normalizeReference`: prepend the configured registry
    /// domain when the reference has none, then apply `library/`+`:latest`
    /// docker.io normalization (via `ContainerizationOCI.Reference`).
    public static func normalizeReference(_ ref: String, registryDomain: String) throws -> String {
        var raw = ref
        if try Reference.parse(ref).domain == nil {
            raw = "\(registryDomain)/\(ref)"
        }
        let parsed = try Reference.parse(raw)
        parsed.normalize()
        return parsed.description
    }

    /// `ClientImage.get`: find a stored image by (normalized) reference.
    /// Locally-built images match on the index descriptor's image-name
    /// annotation before the plain reference comparison.
    public func find(reference: String, registryDomain: String) async throws -> JSONValue? {
        let all = try await list()
        if let annotated = try? Reference.parse(reference) {
            annotated.normalize()
            let want = annotated.description
            let matches = all.filter { desc in
                desc.annotation("org.containerization.image.name") == want
            }
            if let exact = matches.first(where: { $0.reference == want }) ?? matches.first {
                return exact
            }
        }
        let normalized = try Self.normalizeReference(reference, registryDomain: registryDomain)
        return all.first(where: {
            $0.reference == reference || $0.reference == normalized
        })
    }

    /// `ClientImage.fetch`: the local image when it holds `platform`, else a
    /// pull of `platform`. Returns the image `description` to embed in
    /// `ContainerConfiguration.image` with that platform's OCI config, so
    /// the create reads the blobs once.
    ///
    /// A local image holds `platform` only when its index lists it and the
    /// platform's manifest and config blobs are in the content store. A
    /// pull pinned to one platform stores the whole index but only that
    /// platform's blobs, and every pull that names no platform pins
    /// `linux/<host arch>`, so the index alone overstates what is local.
    /// Like `ClientImage.fetch` in container 1.3.1, which resolves
    /// `config(for:)` and pulls on `notFound`, a missing blob counts as
    /// absent. Any other failure is the runtime's and propagates.
    ///
    /// `noPull` (`RunContainerRequest.no_pull`) turns the pull step into a
    /// `notFound:` refusal naming the platform: the caller owns bounded
    /// pulls, and the runtime's `imagePull` has no timeout.
    public func ensure(
        reference: String,
        platform: JSONValue,
        registryDomain: String,
        insecure: Bool = false,
        noPull: Bool = false
    ) async throws -> ResolvedImage {
        if let match = try await find(reference: reference, registryDomain: registryDomain),
            let config = try await localConfig(description: match, platform: platform)
        {
            return ResolvedImage(description: match, config: config)
        }
        if noPull {
            throw Self.notPresentLocally(reference: reference, platform: platform)
        }
        let pulled = try await pull(
            reference: try Self.normalizeReference(reference, registryDomain: registryDomain),
            platform: platform,
            insecure: insecure
        )
        return ResolvedImage(
            description: pulled, config: try await imageConfig(description: pulled, platform: platform))
    }

    /// `platform`'s config from a stored image, or nil when the image does
    /// not hold that platform: its index does not list it, or a blob on the
    /// way (index, manifest, config) is not in the content store.
    private func localConfig(description: JSONValue, platform: JSONValue) async throws -> Image? {
        do {
            return try await imageConfig(description: description, platform: platform)
        } catch let error where ConnectCodeMapping.code(for: error) == "not_found" {
            return nil
        }
    }

    /// The `no_pull` refusal. `notFound:` is the upstream-style prefix
    /// `ConnectCodeMapping` reads as `not_found`; the platform is spelled
    /// `os/arch[/variant]` so a caller can pull exactly the missing variant.
    static func notPresentLocally(reference: String, platform: JSONValue?) -> MicropodError {
        .message("notFound: image \(reference) not present locally for \(platformDescription(platform))")
    }

    static func platformDescription(_ platform: JSONValue?) -> String {
        guard case .object(let fields)? = platform,
            case .string(let os) = fields["os"],
            case .string(let arch) = fields["architecture"]
        else { return "any platform" }
        if case .string(let variant) = fields["variant"], !variant.isEmpty {
            return "\(os)/\(arch)/\(variant)"
        }
        return "\(os)/\(arch)"
    }

    /// Resolve the OCI `Image` (root doc holding `config`) for a stored
    /// image description + platform — index → manifest → config blob.
    /// Returns nil when the index lists no manifest for the platform; a
    /// listed manifest or config whose blob is not stored fails `notFound`.
    public func imageConfig(description: JSONValue, platform: JSONValue) async throws -> Image? {
        guard let index = try await index(for: description),
            let desc = index.manifests.first(where: { Self.matches($0.platform, platform) })
        else { return nil }
        let manifest = try await content(Manifest.self, digest: desc.digest)
        return try await content(Image.self, digest: manifest.config.digest)
    }

    private func index(for description: JSONValue) async throws -> Index? {
        guard case .object(let o) = description,
            case .object(let d) = o["descriptor"],
            case .string(let digest) = d["digest"]
        else { return nil }
        return try await content(Index.self, digest: digest)
    }

    /// Loose platform equality — os/architecture(+variant), tolerating
    /// extra keys either side may carry.
    static func matches(_ p: Platform?, _ want: JSONValue) -> Bool {
        guard let p,
            case .object(let o) = want,
            case .string(let wantOS) = o["os"],
            case .string(let wantArch) = o["architecture"]
        else { return false }
        var wantVariant: String? = nil
        if case .string(let v) = o["variant"] { wantVariant = v }
        // arm64's only defined variant is "v8"; OCI treats it as redundant
        // (Platform's Equatable equates nil and "v8" for arm64).
        let gotVariant = p.variant == "v8" && p.architecture == "arm64" ? nil : p.variant
        if wantVariant == "v8" && wantArch == "arm64" { wantVariant = nil }
        return p.os == wantOS && p.architecture == wantArch && gotVariant == wantVariant
    }
}

private extension JSONValue {
    var reference: String? {
        guard case .object(let o) = self, case .string(let r) = o["reference"] else { return nil }
        return r
    }

    func annotation(_ key: String) -> String? {
        guard case .object(let o) = self,
            case .object(let d) = o["descriptor"],
            case .object(let a) = d["annotations"],
            case .string(let v) = a[key]
        else { return nil }
        return v
    }
}
