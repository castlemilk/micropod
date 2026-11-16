import CryptoKit
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// The native backend's init image guard against a scripted images service:
/// which init image `create` hands the runtime for a requested override,
/// what it looks up and pulls to decide, and the labels that record it.
final class InitImageGuardTests: XCTestCase {
    private static let runtimeDefault = "ghcr.io/apple/containerization/vminit:0.47.0"
    private static let steward = "registry.example.com/vminit:0.47.0-steward.3"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("init-image-guard-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func service(_ store: InitImageStore, runtimeDefault: String? = runtimeDefault, reads: DefaultReads? = nil)
        -> NativeContainerService
    {
        NativeContainerService(
            api: APIServerClient(service: "com.micropod.tests.no-such-apiserver"),
            cli: ContainerService(
                client: ContainerCLIClient(executableURL: root.appendingPathComponent("no-such-cli"))),
            images: ImagesServiceClient(transport: store.transport),
            defaultInitImage: {
                await reads?.count()
                return runtimeDefault
            })
    }

    private func label(_ request: ContainerRunRequest, _ key: String) -> String? {
        request.labels.first { $0.key == key }?.value
    }

    func testBootsAStewardBuiltFromTheRuntimeDefault() async throws {
        let store = try InitImageStore(
            root: root, images: [Self.steward: [InitImageSelection.baseNameLabel: Self.runtimeDefault]])
        let request = await service(store).selectingInitImage(
            ContainerRunRequest(image: "runner:1", noPull: true, initImage: Self.steward), registryDomain: "docker.io")
        XCTAssertEqual(request.initImage, Self.steward)
        XCTAssertEqual(label(request, InitImageSelection.usedLabel), Self.steward)
        XCTAssertNil(label(request, InitImageSelection.fallbackLabel))
        let pulls = await store.pulls
        XCTAssertEqual(pulls, [], "a local image is read, not pulled")
    }

    func testBootsTheDefaultForAnImageBuiltForAnotherRelease() async throws {
        let store = try InitImageStore(
            root: root,
            images: [Self.steward: [InitImageSelection.baseNameLabel: "ghcr.io/apple/containerization/vminit:0.46.0"]])
        let request = await service(store).selectingInitImage(
            ContainerRunRequest(image: "runner:1", noPull: true, initImage: Self.steward), registryDomain: "docker.io")
        XCTAssertNil(request.initImage)
        XCTAssertEqual(label(request, InitImageSelection.usedLabel), Self.runtimeDefault)
        XCTAssertEqual(label(request, InitImageSelection.fallbackLabel), "base-mismatch")
    }

    func testBootsTheDefaultForAnUnlabelledImage() async throws {
        let store = try InitImageStore(root: root, images: [Self.steward: [:]])
        let request = await service(store).selectingInitImage(
            ContainerRunRequest(image: "runner:1", noPull: true, initImage: Self.steward), registryDomain: "docker.io")
        XCTAssertNil(request.initImage)
        XCTAssertEqual(label(request, InitImageSelection.fallbackLabel), "no-base-label")
    }

    func testAMissingImageUnderNoPullBootsTheDefaultWithoutAPull() async throws {
        let store = try InitImageStore(root: root, images: [:])
        let request = await service(store).selectingInitImage(
            ContainerRunRequest(image: "runner:1", noPull: true, initImage: Self.steward), registryDomain: "docker.io")
        XCTAssertNil(request.initImage)
        XCTAssertEqual(label(request, InitImageSelection.fallbackLabel), "unavailable")
        let pulls = await store.pulls
        XCTAssertEqual(pulls, [], "no_pull covers the init image too")
    }

    func testAMissingImageIsPulledForTheHostPlatformWithoutNoPull() async throws {
        let store = try InitImageStore(
            root: root, images: [Self.steward: [InitImageSelection.baseNameLabel: Self.runtimeDefault]],
            stored: false)
        let request = await service(store).selectingInitImage(
            ContainerRunRequest(image: "runner:1", initImage: Self.steward), registryDomain: "docker.io")
        XCTAssertEqual(request.initImage, Self.steward)
        let pulls = await store.pulls
        XCTAssertEqual(pulls, [Self.steward])
    }

    func testAnUnknownDefaultBootsTheDefaultWithoutALookup() async throws {
        let store = try InitImageStore(
            root: root, images: [Self.steward: [InitImageSelection.baseNameLabel: Self.runtimeDefault]])
        let request = await service(store, runtimeDefault: nil).selectingInitImage(
            ContainerRunRequest(image: "runner:1", initImage: Self.steward), registryDomain: "docker.io")
        XCTAssertNil(request.initImage)
        XCTAssertEqual(label(request, InitImageSelection.usedLabel), "default")
        XCTAssertEqual(label(request, InitImageSelection.fallbackLabel), "default-unknown")
        let routes = await store.routes
        XCTAssertEqual(routes, [], "nothing to compare against, so nothing is read")
    }

    func testNoOverrideChangesNothingAndReadsNothing() async throws {
        let store = try InitImageStore(root: root, images: [:])
        let reads = DefaultReads()
        let plain = ContainerRunRequest(image: "runner:1", labels: [LabelSpec(key: "a", value: "b")])
        let request = await service(store, reads: reads).selectingInitImage(plain, registryDomain: "docker.io")
        XCTAssertEqual(request, plain)
        let count = await reads.value
        XCTAssertEqual(count, 0, "the property is read only for an override")
        let routes = await store.routes
        XCTAssertEqual(routes, [])
    }

    // MARK: The default init image property

    func testReadsVminitImageFromTheProperties() {
        let properties: SystemPropertyListResponse = [
            "kernel": ["binaryPath": .string("opt/kata/vmlinux")],
            "vminit": ["image": .string(" \(Self.runtimeDefault) ")],
        ]
        XCTAssertEqual(RuntimeDefaultInitImage.vminitImage(in: properties), Self.runtimeDefault)
        XCTAssertNil(RuntimeDefaultInitImage.vminitImage(in: ["vminit": ["image": .string("")]]))
        XCTAssertNil(RuntimeDefaultInitImage.vminitImage(in: ["vminit": ["image": .number(1)]]))
        XCTAssertNil(RuntimeDefaultInitImage.vminitImage(in: [:]))
    }

    func testKeepsAReadForItsTTLAndRetriesAFailure() async {
        let reads = DefaultReads()
        let failing = RuntimeDefaultInitImage(ttl: .seconds(60)) {
            await reads.count()
            throw MicropodError.message("container CLI failed")
        }
        let first = await failing.value()
        let second = await failing.value()
        XCTAssertNil(first)
        XCTAssertNil(second)
        var count = await reads.value
        XCTAssertEqual(count, 2, "a failed read is not kept")

        let kept = RuntimeDefaultInitImage(ttl: .seconds(60)) {
            await reads.count()
            return Self.runtimeDefault
        }
        let a = await kept.value()
        let b = await kept.value()
        XCTAssertEqual(a, Self.runtimeDefault)
        XCTAssertEqual(b, Self.runtimeDefault)
        count = await reads.value
        XCTAssertEqual(count, 3, "a good read is kept for the TTL")

        let expired = RuntimeDefaultInitImage(ttl: .zero) {
            await reads.count()
            return Self.runtimeDefault
        }
        _ = await expired.value()
        _ = await expired.value()
        count = await reads.value
        XCTAssertEqual(count, 5, "an expired read is taken again")
    }
}

private actor DefaultReads {
    private(set) var value = 0
    func count() { value += 1 }
}

/// The `container-core-images` routes the guard uses, over an on-disk
/// content store: one single-platform image (`linux/<host arch>`) per
/// reference, with the given config labels. `stored: false` keeps only the
/// index until a pull stores the manifest and config.
private actor InitImageStore {
    private(set) var pulls: [String] = []
    private(set) var routes: [String] = []
    private var descriptions: [JSONValue] = []
    private var paths: [String: String] = [:]
    private var blobs: [String: [String]] = [:]
    private var present: Set<String> = []

    init(root: URL, images: [String: [String: String]], stored: Bool = true) throws {
        var paths: [String: String] = [:]
        var blobs: [String: [String]] = [:]
        var present: Set<String> = []
        var descriptions: [JSONValue] = []
        func write(_ json: String) throws -> (digest: String, size: Int) {
            let data = Data(json.utf8)
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try data.write(to: root.appendingPathComponent(hex))
            paths["sha256:\(hex)"] = root.appendingPathComponent(hex).path
            return ("sha256:\(hex)", data.count)
        }
        let architecture = NativeConfigBuilder.hostArchitecture
        for (reference, labels) in images {
            let labelJSON = String(data: try JSONEncoder().encode(labels), encoding: .utf8) ?? "{}"
            let config = try write(
                #"{"architecture":"\#(architecture)","os":"linux","config":{"Labels":\#(labelJSON)},"#
                    + #""rootfs":{"type":"layers","diff_ids":[]}}"#)
            let manifest = try write(
                #"{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","#
                    + #""config":{"mediaType":"application/vnd.oci.image.config.v1+json","#
                    + #""digest":"\#(config.digest)","size":\#(config.size)},"layers":[]}"#)
            let index = try write(
                #"{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":["#
                    + #"{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"\#(manifest.digest)","#
                    + #""size":\#(manifest.size),"platform":{"architecture":"\#(architecture)","os":"linux"}}]}"#)
            blobs[reference] = [manifest.digest, config.digest]
            present.insert(index.digest)
            if stored { present.formUnion([manifest.digest, config.digest]) }
            descriptions.append(
                .object([
                    "reference": .string(reference),
                    "descriptor": .object([
                        "mediaType": .string("application/vnd.oci.image.index.v1+json"),
                        "digest": .string(index.digest),
                        "size": .number(Double(index.size)),
                    ]),
                ]))
        }
        self.paths = paths
        self.blobs = blobs
        self.present = present
        self.descriptions = descriptions
    }

    nonisolated var transport: ImagesServiceClient.Transport {
        { request, _ in try await self.handle(request) }
    }

    private func handle(_ request: XPCMessage) throws -> XPCMessage {
        let route = request.string(key: XPCMessage.routeKey) ?? ""
        routes.append(route)
        let reply = XPCMessage(route: "reply")
        switch route {
        case ImagesRoute.imageList.rawValue:
            reply.set(key: .imageDescriptions, value: try JSONEncoder().encode(descriptions))
        case ImagesRoute.contentGet.rawValue:
            let digest = request.string(key: .digest) ?? ""
            guard present.contains(digest), let path = paths[digest] else {
                throw MicropodError.message("notFound: digest \(digest) not found")
            }
            reply.set(key: .contentPath, value: path)
        case ImagesRoute.imagePull.rawValue:
            let reference = request.string(key: .imageReference) ?? ""
            pulls.append(reference)
            guard let stored = blobs[reference],
                let description = descriptions.first(where: {
                    if case .object(let fields) = $0, case .string(reference)? = fields["reference"] { return true }
                    return false
                })
            else {
                throw MicropodError.message("notFound: \(reference) not in the registry")
            }
            present.formUnion(stored)
            reply.set(key: .imageDescription, value: try JSONEncoder().encode(description))
        default:
            throw MicropodError.message("unexpected route \(route)")
        }
        return reply
    }
}
