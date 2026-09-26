import CryptoKit
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// `ImagesServiceClient.ensure` against a scripted images service holding
/// what a pull pinned to one platform leaves behind: the image's whole
/// index, but only that platform's manifest and config blobs. Every
/// `PullImage` that names no platform pins `linux/<host arch>`, so a
/// platform the index lists is not necessarily local. It is local only when
/// its manifest and config resolve (`ClientImage.fetch` in container 1.3.1
/// resolves `config(for:)` and pulls on `notFound`); otherwise a create
/// pulls that platform or, under `no_pull`, refuses naming it.
final class ImageEnsureTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-ensure-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let amd64: JSONValue = .object(["os": .string("linux"), "architecture": .string("amd64")])
    private static let arm64: JSONValue = .object(["os": .string("linux"), "architecture": .string("arm64")])
    private static let arm64v8: JSONValue = .object([
        "os": .string("linux"), "architecture": .string("arm64"), "variant": .string("v8"),
    ])

    /// Without `no_pull`, a platform the index lists but whose manifest is
    /// not stored is pulled for that platform, and the create gets that
    /// platform's config (before: the host-only copy was returned and the
    /// config read failed `notFound: digest … not found`).
    func testListedPlatformWithoutBlobsIsPulledForThatPlatform() async throws {
        let store = try ScriptedImageStore(root: root, storedArchitectures: ["arm64"])
        let images = ImagesServiceClient(transport: store.transport)

        let resolved = try await images.ensure(
            reference: "alpine:3.20", platform: Self.amd64, registryDomain: "docker.io")

        let pulls = await store.pulls
        XCTAssertEqual(pulls.count, 1, "the amd64 variant must be pulled: \(pulls)")
        XCTAssertEqual(pulls.first?.reference, "docker.io/library/alpine:3.20")
        XCTAssertEqual(pulls.first?.platform, Self.amd64)
        XCTAssertEqual(resolved.description, store.description)
        XCTAssertEqual(resolved.config?.architecture, "amd64")
        XCTAssertEqual(resolved.config?.config?.cmd, ["/bin/sh", "amd64"])
    }

    /// Under `no_pull` the same image is `not_found` naming the platform the
    /// caller must pull — not the digest error from the config read.
    func testNoPullRefusesAListedPlatformWithoutBlobs() async throws {
        let store = try ScriptedImageStore(root: root, storedArchitectures: ["arm64"])
        let images = ImagesServiceClient(transport: store.transport)

        do {
            let resolved = try await images.ensure(
                reference: "alpine:3.20", platform: Self.amd64, registryDomain: "docker.io", noPull: true)
            XCTFail("no_pull must refuse the amd64 variant the store lacks, got \(resolved.description)")
        } catch {
            XCTAssertEqual(
                error.localizedDescription, "notFound: image alpine:3.20 not present locally for linux/amd64")
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "not_found")
        }
        let pulls = await store.pulls
        XCTAssertTrue(pulls.isEmpty, "no_pull never pulls: \(pulls)")
    }

    /// The stored platform resolves locally, with or without arm64's
    /// redundant `v8` variant, and nothing is pulled.
    func testStoredPlatformResolvesWithoutPull() async throws {
        let store = try ScriptedImageStore(root: root, storedArchitectures: ["arm64"])
        let images = ImagesServiceClient(transport: store.transport)

        for platform in [Self.arm64, Self.arm64v8] {
            for noPull in [false, true] {
                let resolved = try await images.ensure(
                    reference: "alpine:3.20", platform: platform, registryDomain: "docker.io", noPull: noPull)
                XCTAssertEqual(resolved.description, store.description)
                XCTAssertEqual(resolved.config?.architecture, "arm64", "\(platform) noPull=\(noPull)")
                XCTAssertEqual(resolved.config?.config?.cmd, ["/bin/sh", "arm64"])
            }
        }
        let pulls = await store.pulls
        XCTAssertTrue(pulls.isEmpty, "a stored platform is never pulled: \(pulls)")
    }

    /// Only `notFound` means "not local". Any other failure reading the
    /// manifest is the runtime's and propagates: it is neither a pull nor a
    /// `no_pull` refusal claiming the image is absent.
    func testRuntimeFailureReadingTheManifestPropagates() async throws {
        let store = try ScriptedImageStore(root: root, storedArchitectures: ["arm64", "amd64"])
        await store.failManifestReads(with: MicropodError.transport("container-core-images: Connection interrupted"))
        let images = ImagesServiceClient(transport: store.transport)

        for noPull in [false, true] {
            do {
                let resolved = try await images.ensure(
                    reference: "alpine:3.20", platform: Self.amd64, registryDomain: "docker.io", noPull: noPull)
                XCTFail("noPull=\(noPull): the failed read must propagate, got \(resolved.description)")
            } catch {
                XCTAssertEqual(ConnectCodeMapping.code(for: error), "unavailable", "noPull=\(noPull): \(error)")
            }
        }
        let pulls = await store.pulls
        XCTAssertTrue(pulls.isEmpty, "a failed read is not a reason to pull: \(pulls)")
    }
}

/// The `container-core-images` routes `ensure` uses, over an on-disk content
/// store of real OCI JSON: an index listing `linux/arm64/v8` and
/// `linux/amd64`, and per platform a manifest and config blob that are
/// present only for `storedArchitectures` (a pull of a platform stores its
/// blobs). A missing blob fails `contentGet` with the error upstream's
/// `ContainerizationError(.notFound, "digest … not found")` reaches the
/// client as.
private actor ScriptedImageStore {
    struct Pull: Equatable {
        let reference: String
        let platform: JSONValue?
    }

    nonisolated let description: JSONValue
    private(set) var pulls: [Pull] = []
    private let paths: [String: String]
    private let indexDigest: String
    private let blobsByArchitecture: [String: [String]]
    private var present: Set<String>
    private var manifestReadFailure: Error?

    init(root: URL, storedArchitectures: Set<String>) throws {
        var paths: [String: String] = [:]
        func write(_ json: String) throws -> (digest: String, size: Int) {
            let data = Data(json.utf8)
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let url = root.appendingPathComponent(hex)
            try data.write(to: url)
            paths["sha256:\(hex)"] = url.path
            return ("sha256:\(hex)", data.count)
        }
        var blobsByArchitecture: [String: [String]] = [:]
        var manifestEntries: [String] = []
        for (architecture, variant) in [("arm64", "v8"), ("amd64", "")] {
            let variantField = variant.isEmpty ? "" : #","variant":"\#(variant)""#
            let config = try write(
                #"{"architecture":"\#(architecture)","os":"linux"\#(variantField),"#
                    + #""config":{"Cmd":["/bin/sh","\#(architecture)"]},"rootfs":{"type":"layers","diff_ids":[]}}"#)
            let manifest = try write(
                #"{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","#
                    + #""config":{"mediaType":"application/vnd.oci.image.config.v1+json","#
                    + #""digest":"\#(config.digest)","size":\#(config.size)},"layers":[]}"#)
            blobsByArchitecture[architecture] = [manifest.digest, config.digest]
            manifestEntries.append(
                #"{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"\#(manifest.digest)","#
                    + #""size":\#(manifest.size),"platform":{"architecture":"\#(architecture)","os":"linux""#
                    + #"\#(variantField)}}"#)
        }
        let index = try write(
            #"{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":["#
                + manifestEntries.joined(separator: ",") + "]}")
        self.paths = paths
        self.indexDigest = index.digest
        self.blobsByArchitecture = blobsByArchitecture
        self.present = Set([index.digest] + storedArchitectures.flatMap { blobsByArchitecture[$0] ?? [] })
        self.description = .object([
            "reference": .string("docker.io/library/alpine:3.20"),
            "descriptor": .object([
                "mediaType": .string("application/vnd.oci.image.index.v1+json"),
                "digest": .string(index.digest),
                "size": .number(Double(index.size)),
            ]),
        ])
    }

    nonisolated var transport: ImagesServiceClient.Transport {
        { request, _ in try await self.handle(request) }
    }

    func failManifestReads(with error: Error) {
        manifestReadFailure = error
    }

    private func handle(_ request: XPCMessage) throws -> XPCMessage {
        let reply = XPCMessage(route: "reply")
        switch request.string(key: XPCMessage.routeKey) {
        case ImagesRoute.imageList.rawValue:
            reply.set(key: .imageDescriptions, value: try JSONEncoder().encode([description]))
        case ImagesRoute.contentGet.rawValue:
            let digest = request.string(key: .digest) ?? ""
            if digest != indexDigest, let manifestReadFailure { throw manifestReadFailure }
            guard present.contains(digest), let path = paths[digest] else {
                throw MicropodError.message("notFound: digest \(digest) not found")
            }
            reply.set(key: .contentPath, value: path)
        case ImagesRoute.imagePull.rawValue:
            let platform = try request.data(key: .ociPlatform).map {
                try JSONDecoder().decode(JSONValue.self, from: $0)
            }
            pulls.append(Pull(reference: request.string(key: .imageReference) ?? "", platform: platform))
            if case .object(let fields)? = platform, case .string(let architecture) = fields["architecture"] {
                present.formUnion(blobsByArchitecture[architecture] ?? [])
            } else {
                present.formUnion(blobsByArchitecture.values.flatMap { $0 })
            }
            reply.set(key: .imageDescription, value: try JSONEncoder().encode(description))
        default:
            throw MicropodError.message("unexpected route \(request.string(key: XPCMessage.routeKey) ?? "nil")")
        }
        return reply
    }
}
