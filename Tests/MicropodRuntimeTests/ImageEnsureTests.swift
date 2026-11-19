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

    func testNativeNoPullRefusalDoesNotRetainCreateIntent() async throws {
        let store = try ScriptedImageStore(root: root, storedArchitectures: ["arm64"])
        let gate = try enrolledCreateGate()
        let service = nativeService(images: ImagesServiceClient(transport: store.transport), gate: gate)
        do {
            _ = try await service.create(
                ContainerRunRequest(
                    image: "alpine:3.20", name: "missing-platform", platform: "linux/amd64", noPull: true))
            XCTFail("the missing platform must be refused")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "not_found")
        }
        let fence = try gate.begin(operation: UUID())
        try fence.releaseAfterVerification()
        let pulls = await store.pulls
        XCTAssertTrue(pulls.isEmpty)
    }

    func testNativeImageReadFailureDoesNotRetainCreateIntent() async throws {
        let store = try ScriptedImageStore(root: root, storedArchitectures: ["arm64", "amd64"])
        await store.failManifestReads(with: MicropodError.transport("image lookup interrupted"))
        let gate = try enrolledCreateGate()
        let service = nativeService(images: ImagesServiceClient(transport: store.transport), gate: gate)
        do {
            _ = try await service.create(
                ContainerRunRequest(image: "alpine:3.20", name: "failed-lookup", platform: "linux/amd64", noPull: true))
            XCTFail("the read failure must propagate")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "unavailable")
        }
        let fence = try gate.begin(operation: UUID())
        try fence.releaseAfterVerification()
    }

    /// A create that fails after image resolution but before
    /// `containerCreate` was sent settles its receipt as a definitive
    /// failure: the runtime cannot hold a container it was never asked for.
    /// Here the container service is unreachable, so the first runtime read
    /// (the network list) fails `unavailable` — which used to leave an
    /// uncertain `native.create` receipt, the kind Gamma-128's drain watcher
    /// waited on for an hour. A create that did send `containerCreate`
    /// still keeps an uncertain receipt when it gets no authoritative answer.
    func testNativeFailureBeforeContainerCreateSettlesItsReceipt() async throws {
        let store = try ScriptedImageStore(root: root, storedArchitectures: ["amd64"])
        let gate = try enrolledCreateGate()
        let service = nativeService(images: ImagesServiceClient(transport: store.transport), gate: gate)
        do {
            _ = try await service.create(
                ContainerRunRequest(image: "alpine:3.20", name: "unknown-create", platform: "linux/amd64", noPull: true)
            )
            XCTFail("the unavailable container service must refuse creation")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "unavailable")
        }
        let pending = gate.root.appendingPathComponent("pending")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: pending.path), [],
            "nothing was sent, so nothing is uncertain")
        try gate.begin(operation: UUID()).releaseAfterVerification()
    }

    /// A caller that gives up (the API cancels the handler when its client
    /// hangs up or its Connect deadline passes) before the create is sent:
    /// the create stops, sends nothing, and leaves no receipt.
    func testCancelledCreateSendsNothingAndLeavesNoReceipt() async throws {
        let store = try ScriptedImageStore(root: root, storedArchitectures: ["amd64"])
        let gate = try enrolledCreateGate()
        let service = nativeService(images: ImagesServiceClient(transport: store.transport), gate: gate)
        let create = Task {
            try await service.create(
                ContainerRunRequest(image: "alpine:3.20", name: "abandoned", platform: "linux/amd64", noPull: true))
        }
        create.cancel()
        do {
            _ = try await create.value
            XCTFail("a cancelled create must not succeed")
        } catch {
            XCTAssertTrue(
                error is CancellationError || ConnectCodeMapping.code(for: error) == "canceled",
                "stopped by the cancellation, not by the runtime: \(error)")
        }
        let pending = gate.root.appendingPathComponent("pending")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pending.path), [])
        try gate.begin(operation: UUID()).releaseAfterVerification()
    }

    func testRejectedMountsDoNotBlockMaintenance() async throws {
        let store = try ScriptedImageStore(root: root, storedArchitectures: ["amd64"])
        let gate = try enrolledCreateGate()
        let service = nativeService(images: ImagesServiceClient(transport: store.transport), gate: gate)
        let missing = root.appendingPathComponent("missing-bind").path
        let requests = [
            ContainerRunRequest(
                image: "alpine:3.20", name: "missing-bind",
                volumes: [missing + ":/input:ro"], platform: "linux/amd64", noPull: true),
            ContainerRunRequest(
                image: "alpine:3.20", name: "invalid-volume",
                volumes: ["cache:/input:ro:extra"], platform: "linux/amd64", noPull: true),
            ContainerRunRequest(
                image: "alpine:3.20", name: "invalid-tmpfs",
                tmpfs: ["relative"], platform: "linux/amd64", noPull: true),
        ]
        for request in requests {
            do {
                _ = try await service.create(request)
                XCTFail("invalid mounts must be rejected before contacting the container service")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("Connection"), "\(error)")
            }
            let fence = try gate.begin(operation: UUID())
            try fence.releaseAfterVerification()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
    }

    func testNativeCreateRechecksFenceAfterImageLookup() async throws {
        let store = try ScriptedImageStore(root: root, storedArchitectures: ["amd64"])
        let gate = try enrolledCreateGate()
        let closer = ImageLookupFence(gate: gate)
        let images = ImagesServiceClient(transport: { request, timeout in
            let reply = try await store.transport(request, timeout)
            if request.string(key: XPCMessage.routeKey) == ImagesRoute.imageList.rawValue {
                try await closer.close()
            }
            return reply
        })
        let service = nativeService(images: images, gate: gate)
        do {
            _ = try await service.create(
                ContainerRunRequest(image: "alpine:3.20", name: "late-fence", platform: "linux/amd64", noPull: true))
            XCTFail("a fence acquired during lookup must prevent creation")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("closed workload admission"), "\(error)")
        }
        XCTAssertTrue(gate.isClosed)
        let pending = try FileManager.default.contentsOfDirectory(
            at: gate.root.appendingPathComponent("pending"), includingPropertiesForKeys: nil)
        XCTAssertTrue(pending.isEmpty, "the refused create must not leave an uncertain mutation")
        try await closer.release()
    }

    private func enrolledCreateGate() throws -> RuntimeAdmission {
        let gate = RuntimeAdmission(root: root.appendingPathComponent("admission"))
        let fence = try gate.begin(operation: UUID())
        try fence.releaseAfterVerification()
        return gate
    }

    private func nativeService(images: ImagesServiceClient, gate: RuntimeAdmission) -> NativeContainerService {
        NativeContainerService(
            api: APIServerClient(service: "com.micropod.tests.no-such-apiserver"),
            cli: ContainerService(
                client: ContainerCLIClient(executableURL: root.appendingPathComponent("no-such-cli"))),
            images: images, admissionGate: gate)
    }
}

private actor ImageLookupFence {
    let gate: RuntimeAdmission
    private var fence: RuntimeMaintenanceFence?
    init(gate: RuntimeAdmission) { self.gate = gate }
    func close() throws { fence = try gate.begin(operation: UUID()) }
    func release() throws {
        try fence?.releaseAfterVerification()
        fence = nil
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
