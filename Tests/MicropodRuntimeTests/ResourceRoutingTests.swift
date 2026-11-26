import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Volume and image routing (`VolumeRouter`, `ImageRouter`) without a VM:
/// Apple-only setups pass straight through unchanged; with the hvf engine
/// enabled, a fake guest Docker API on the machine socket stands in for the
/// guest, answering the way the real one does (`scripts/e2e_hvf.sh` checks
/// the same calls live).
final class ResourceRoutingTests: XCTestCase {
    private var root: URL!
    private var configURL: URL!
    private var held: [HVFFileLock] = []
    private var server: FakeDockerServer?

    override func setUp() {
        // Short on purpose: run/docker.sock must fit sockaddr_un.
        root = URL(fileURLWithPath: "/tmp/mphvf-v-\(UUID().uuidString.prefix(8))")
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent("runtimes-\(UUID().uuidString).json")
    }

    override func tearDown() {
        server?.stop()
        for lock in held { lock.release() }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: configURL)
    }

    private var layout: HVFMachineLayout { HVFMachineLayout(root: root) }

    private func registry(hvf: Bool, default name: String? = nil) throws -> EngineRegistry {
        var environment = [
            "MICROPOD_RUNTIMES_CONFIG": configURL.path, "DOCKER_HOST": "unix:///nonexistent.sock",
            "MICROPOD_HVF_ROOT": root.path,
        ]
        if let name { environment["MICROPOD_DEFAULT_RUNTIME"] = name }
        let registry = EngineRegistry(
            environment: environment,
            sandbox: SandboxEngine(root: FileManager.default.temporaryDirectory.appendingPathComponent("sbx-\(UUID())"))
        )
        if hvf { try registry.update("hvf", enabled: true, endpoint: nil) }
        return registry
    }

    private func installPlaceholders() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.tools.appendingPathComponent("runner"), withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.runDirectory, withIntermediateDirectories: true)
        for url in [
            layout.vmm, layout.kernel, layout.initrd, layout.disk,
            layout.tools.appendingPathComponent("runner/start.sh"),
        ] {
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data("x".utf8)))
        }
        XCTAssertEqual(chmod(layout.vmm.path, 0o755), 0)
    }

    private func hold(_ url: URL) throws {
        held.append(try XCTUnwrap(try HVFFileLock.acquire(url, wait: .zero)))
    }

    /// A running machine whose guest API is `route`.
    @discardableResult
    private func serving(_ route: @escaping FakeDockerServer.Route) throws -> FakeDockerServer {
        try installPlaceholders()
        try hold(layout.supervisorLock)
        try HVFMachineState(phase: .running, supervisorPID: getpid()).save(to: layout.state)
        let server = try FakeDockerServer(path: layout.dockerSocket.path, route: route)
        self.server = server
        return server
    }

    private static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func failure(_ body: () async throws -> Void) async -> (code: String, message: String)? {
        do {
            try await body()
            return nil
        } catch {
            return (ConnectCodeMapping.code(for: error), error.localizedDescription)
        }
    }

    /// The guest as the current tool bundles serve it.
    private static let guest: FakeDockerServer.Route = { request in
        switch (request.method, request.path) {
        case ("GET", "/version"): return (200, json(["ApiVersion": "1.47", "MinAPIVersion": "1.44"]))
        case ("GET", "/volumes"):
            return (
                200,
                json([
                    "Volumes": [
                        [
                            "Name": "cache", "Driver": "local", "Mountpoint": "/var/lib/micropod/engine/volumes/cache",
                            "CreatedAt": "2026-11-25T16:16:56Z", "Labels": ["k": "v"],
                        ],
                        ["Name": "both", "Driver": "local", "Labels": [String: String]()],
                    ],
                    "Warnings": [String](),
                ])
            )
        case ("GET", "/volumes/cache"), ("GET", "/volumes/both"): return (200, json(["Name": "x"]))
        case ("GET", _) where request.path.hasPrefix("/volumes/"): return (404, json(["message": "no such volume"]))
        case ("POST", "/volumes/create"): return (201, json(["Name": "made"]))
        case ("DELETE", "/volumes/cache"): return (204, Data())
        case ("DELETE", "/volumes/both"): return (409, json(["message": "volume is in use"]))
        case ("DELETE", _) where request.path.hasPrefix("/volumes/"): return (404, json(["message": "no such volume"]))
        case ("GET", "/images/json"):
            return (
                200,
                json([
                    [
                        "Id": "sha256:ab3f", "RepoTags": ["docker.io/library/busybox:1.36"],
                        "RepoDigests": ["docker.io/library/busybox@sha256:73aa"], "Size": 1_900_000, "Os": "linux",
                        "Architecture": "arm64",
                    ]
                ])
            )
        case ("GET", "/images/busybox:1.36/json"), ("GET", "/images/alpine:3.20/json"):
            return (200, json(["Id": "sha256:ab3f"]))
        case ("GET", _) where request.path.hasPrefix("/images/"): return (404, json(["message": "No such image"]))
        case ("POST", "/images/create"):
            if request.query["fromImage"] == "nonexistent.invalid/x:1" {
                return (500, json(["message": "failed to resolve image"]))
            }
            return (200, Data(#"{"status":"Downloaded \#(request.query["fromImage"] ?? "")"}"#.utf8))
        default: return (501, json(["message": "unsupported image operation"]))
        }
    }

    // MARK: Apple only

    func testWithoutRoutingEveryCallIsApplesUnchanged() async throws {
        let volumes = RecordingVolumes()
        let images = RecordingImages()
        for registry in [nil, try registry(hvf: false)] {
            let volumeRouter = VolumeRouter(apple: volumes, registry: registry)
            let imageRouter = ImageRouter(apple: images, registry: registry)
            let listed = try await volumeRouter.list()
            XCTAssertEqual(listed, RecordingVolumes.listing, "no stamp, no merge")
            try await volumeRouter.create(name: "v", size: "1g", labels: ["a=b"], options: ["o=p"])
            try await volumeRouter.delete("v")
            let pruned = try await volumeRouter.prune()
            XCTAssertEqual(pruned, "apple pruned volumes", "Apple's report verbatim")
            _ = try await volumeRouter.clone(source: "golden", name: "copy", size: nil, labels: [])
            _ = try await volumeRouter.commitClone(containerID: "job", volume: "golden")

            let imageList = try await imageRouter.list()
            XCTAssertEqual(imageList, RecordingImages.listing)
            for try await _ in imageRouter.pull("alpine:3.20", platform: nil) {}
            try await imageRouter.delete("alpine:3.20", force: true)
            try await imageRouter.tag(source: "alpine:3.20", target: "mine:1")
            _ = try await imageRouter.inspect("alpine:3.20")
            let imagePrune = try await imageRouter.prune(danglingOnly: false)
            XCTAssertEqual(imagePrune, "apple pruned images")
            try await imageRouter.save("alpine:3.20", to: "/tmp/x.tar")
            try await imageRouter.load(from: "/tmp/x.tar")
            for try await _ in imageRouter.push("alpine:3.20", platform: "linux/arm64") {}
            for try await _ in imageRouter.build(ContainerBuildRequest(contextDirectory: ".")) {}
        }
        let volumeCalls = await volumes.calls
        XCTAssertEqual(
            volumeCalls,
            Array(
                repeating: [
                    "list", "create v size=1g labels=a=b options=o=p", "delete v", "prune", "clone golden->copy",
                    "commit job golden",
                ], count: 2
            ).flatMap { $0 })
        let imageCalls = await images.calls
        XCTAssertEqual(
            imageCalls,
            Array(
                repeating: [
                    "list", "pull alpine:3.20 platform=nil", "delete alpine:3.20 force=true",
                    "tag alpine:3.20->mine:1", "inspect alpine:3.20", "prune dangling=false",
                    "save alpine:3.20", "load /tmp/x.tar", "push alpine:3.20 platform=linux/arm64", "build .",
                ], count: 2
            ).flatMap { $0 })
    }

    func testANamedRuntimeIsValidatedLikeContainers() async throws {
        let router = VolumeRouter(apple: RecordingVolumes(), registry: try registry(hvf: false))
        let disabled = await failure {
            try await router.create(name: "v", size: nil, labels: [], options: [], runtime: "hvf")
        }
        XCTAssertEqual(disabled?.code, "failed_precondition")
        XCTAssertTrue(disabled?.message.contains("disabled") ?? false, disabled?.message ?? "")
        let unknown = await failure { _ = try await router.list(runtime: "firecracker") }
        XCTAssertEqual(unknown?.code, "failed_precondition")
        let noStore = await failure { _ = try await router.list(runtime: "sandbox") }
        XCTAssertEqual(noStore?.code, "unimplemented", "sandbox keeps no volumes")
        let unrouted = await failure {
            try await VolumeRouter(apple: RecordingVolumes(), registry: nil).delete("v", runtime: "hvf")
        }
        XCTAssertEqual(unrouted?.code, "failed_precondition")
        let apple = try await router.list(runtime: "apple")
        XCTAssertEqual(apple, RecordingVolumes.listing)
    }

    func testAnotherDefaultWithoutAStoreKeepsCreatesOnApple() async throws {
        let volumes = RecordingVolumes()
        let router = VolumeRouter(apple: volumes, registry: try registry(hvf: false, default: "sandbox"))
        try await router.create(name: "v", size: nil, labels: [], options: [])
        let calls = await volumes.calls
        XCTAssertEqual(calls, ["create v size=nil labels= options="], "sandbox keeps no volumes: Apple, as before")
    }

    // MARK: hvf volumes

    func testVolumesMergeStampAndRouteToTheirOwner() async throws {
        let server = try serving(Self.guest)
        let apple = RecordingVolumes(names: ["data", "both"])
        let router = VolumeRouter(apple: apple, registry: try registry(hvf: true))

        let listed = try await router.list()
        XCTAssertEqual(listed.map(\.id), ["data", "both", "cache", "both"])
        XCTAssertEqual(listed.map(RuntimeStamp.runtime(of:)), ["apple", "apple", "hvf", "hvf"])
        XCTAssertEqual(listed[0].labels, [:], "Apple's volumes are listed as Apple reports them")
        XCTAssertEqual(listed[2].labels, ["k": "v", RuntimeStamp.volumeLabel: "hvf"])
        XCTAssertEqual(listed[2].source, "/var/lib/micropod/engine/volumes/cache")
        let onlyHVF = try await router.list(runtime: "hvf")
        XCTAssertEqual(onlyHVF.map(\.id), ["cache", "both"])

        try await router.create(
            name: "made", size: nil, labels: ["a=b", "\(RuntimeStamp.volumeLabel)=x"], options: [], runtime: "hvf")
        let create = try XCTUnwrap(server.requests.last { $0.path == "/volumes/create" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: create.body) as? [String: Any])
        XCTAssertEqual(body["Name"] as? String, "made")
        XCTAssertEqual(body["Labels"] as? [String: String], ["a": "b"], "the listing stamp is never stored")
        XCTAssertNil(body["DriverOpts"])
        let sized = await failure {
            try await router.create(name: "big", size: "1g", labels: [], options: [], runtime: "hvf")
        }
        XCTAssertEqual(sized?.code, "unimplemented")
        XCTAssertTrue(sized?.message.contains("size or driver options") ?? false, sized?.message ?? "")
        try await router.create(name: "plain", size: nil, labels: [], options: [])

        try await router.delete("cache")
        let ownedByBoth = try await router.runtime(of: "both")
        XCTAssertEqual(ownedByBoth, "apple", "the default runtime wins a name both engines have")
        try await router.delete("data")
        let inUse = await failure { try await router.delete("both", runtime: "hvf") }
        XCTAssertEqual(inUse?.code, "failed_precondition", inUse?.message ?? "")
        XCTAssertTrue(inUse?.message.contains("in use") ?? false)
        let missing = await failure { try await router.delete("ghost", runtime: "hvf") }
        XCTAssertEqual(missing?.code, "not_found")

        XCTAssertEqual(
            server.requests.filter { $0.method == "DELETE" }.map(\.path),
            ["/volumes/cache", "/volumes/both", "/volumes/ghost"])
        let appleCalls = await apple.calls
        XCTAssertEqual(
            appleCalls.filter { !$0.hasPrefix("list") },
            ["create plain size=nil labels= options=", "delete data"], "unnamed creates stay on the default (apple)")

        let pruned = try await router.prune()
        XCTAssertEqual(pruned, "apple pruned volumes", "an engine without prune is skipped")
        let hvfPrune = await failure { _ = try await router.prune(runtime: "hvf") }
        XCTAssertEqual(hvfPrune?.code, "unimplemented")
        XCTAssertTrue(hvfPrune?.message.contains("volume prune") ?? false)
        XCTAssertFalse(server.requests.contains { $0.path == "/volumes/prune" }, "nothing is sent for it")
        let clone = await failure { _ = try await router.clone(source: "cache", name: "c2", size: nil, labels: []) }
        XCTAssertEqual(clone?.code, "unimplemented", "clones are Apple's")
    }

    func testAnHVFDefaultTakesUnnamedCreatesAndItsOwnNames() async throws {
        let server = try serving(Self.guest)
        let apple = RecordingVolumes(names: ["data", "both"])
        let router = VolumeRouter(apple: apple, registry: try registry(hvf: true, default: "hvf"))
        try await router.create(name: "made", size: nil, labels: [], options: [])
        XCTAssertTrue(server.requests.contains { $0.path == "/volumes/create" })
        let both = try await router.runtime(of: "both")
        XCTAssertEqual(both, "hvf")
        let appleOnly = try await router.runtime(of: "data")
        XCTAssertEqual(appleOnly, "apple", "Apple still owns what only it has")
        let nobody = try await router.runtime(of: "ghost")
        XCTAssertEqual(nobody, "hvf", "no owner: the default engine answers")
    }

    func testAStoppedMachineListsNothingAndCreateBootsIt() async throws {
        try installPlaceholders()
        let apple = RecordingVolumes(names: ["data"])
        let router = VolumeRouter(apple: apple, registry: try registry(hvf: true))
        let listed = try await router.list()
        XCTAssertEqual(listed.map(\.id), ["data"])
        let owner = try await router.runtime(of: "data")
        XCTAssertEqual(owner, "apple")
        let delete = await failure { try await router.delete("cache", runtime: "hvf") }
        XCTAssertEqual(delete?.code, "failed_precondition")
        XCTAssertTrue(delete?.message.contains("micropod machine start") ?? false, delete?.message ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.state.path), "reads never boot the machine")
        try hold(layout.installLock)
        let create = await failure {
            try await router.create(name: "v", size: nil, labels: [], options: [], runtime: "hvf")
        }
        XCTAssertTrue(create?.message.contains("is being installed") ?? false, "create boots: \(create?.message ?? "")")
    }

    func testAStoppedAppleRuntimeOnlyFailsTheListingWhenItIsTheDefault() async throws {
        try serving(Self.guest)
        let down = RecordingVolumes(failure: MicropodError.runtimeNotRunning)
        let appleDefault = VolumeRouter(apple: down, registry: try registry(hvf: true))
        let failed = await failure { _ = try await appleDefault.list() }
        XCTAssertNotNil(failed)
        let hvfDefault = VolumeRouter(apple: down, registry: try registry(hvf: true, default: "hvf"))
        let listed = try await hvfDefault.list()
        XCTAssertEqual(listed.map(\.id), ["cache", "both"])
    }

    // MARK: hvf images

    func testImagesMergeAndPullOnTheNamedRuntime() async throws {
        let server = try serving(Self.guest)
        let apple = RecordingImages()
        let router = ImageRouter(apple: apple, registry: try registry(hvf: true))
        let listed = try await router.listByRuntime()
        XCTAssertEqual(listed.map(\.runtime), ["apple", "hvf"])
        let busybox = listed[1].image
        XCTAssertEqual(busybox.names, ["docker.io/library/busybox:1.36"])
        XCTAssertEqual(busybox.digest, "sha256:73aa")
        XCTAssertEqual(busybox.sizeBytes, 1_900_000)
        XCTAssertEqual(busybox.variants.map { "\($0.os)/\($0.architecture)" }, ["linux/arm64"])

        var lines: [String] = []
        for try await event in router.pull("busybox:1.36", platform: nil, runtime: "hvf") { lines.append(event.line) }
        XCTAssertEqual(lines, ["Downloaded busybox:1.36"])
        let pull = try XCTUnwrap(server.requests.last { $0.path == "/images/create" })
        XCTAssertEqual(pull.query, ["fromImage": "busybox:1.36"], "no platform unless asked for")
        let failed = await failure {
            for try await _ in router.pull("nonexistent.invalid/x:1", platform: nil, runtime: "hvf") {}
        }
        XCTAssertEqual(failed?.code, "internal")
        XCTAssertTrue(failed?.message.contains("failed to resolve image") ?? false, failed?.message ?? "")
        for try await _ in router.pull("alpine:3.20", platform: nil) {}
        let applePulls = await apple.calls
        XCTAssertTrue(applePulls.contains("pull alpine:3.20 platform=nil"), "an unnamed pull takes the default")

        // The guest answers 501 for these: refused here without a request.
        let sent = server.requests.count
        for (name, call) in [
            ("rmi", { try await router.delete("busybox:1.36", force: false) }),
            ("rmi named", { try await router.delete("alpine:3.20", force: true, runtime: "hvf") }),
            ("tag", { try await router.tag(source: "busybox:1.36", target: "mine:1") }),
            ("prune", { _ = try await router.prune(danglingOnly: true, runtime: "hvf") }),
            ("push", { for try await _ in router.push("busybox:1.36", platform: nil) {} }),
            (
                "build",
                { for try await _ in router.build(ContainerBuildRequest(contextDirectory: "."), runtime: "hvf") {} }
            ),
        ] as [(String, () async throws -> Void)] {
            let refused = await failure(call)
            XCTAssertEqual(refused?.code, "unimplemented", "\(name): \(refused?.message ?? "succeeded")")
            XCTAssertTrue(refused?.message.contains("runtime 'hvf' does not support") ?? false, name)
        }
        XCTAssertFalse(
            server.requests.dropFirst(sent).contains { $0.method != "GET" }, "only ownership lookups reached the guest")

        let inspected = try await router.inspect("busybox:1.36")
        XCTAssertEqual(String(decoding: inspected, as: UTF8.self), #"{"Id":"sha256:ab3f"}"#)
        let appleOwned = try await router.runtime(of: "docker.io/library/alpine:3.20")
        XCTAssertEqual(appleOwned, "apple", "Apple's names match however the reference is spelled")
        let pruned = try await router.prune(danglingOnly: true)
        XCTAssertEqual(pruned, "apple pruned images")
    }

    func testSaveAndLoadGoToTheHVFGuest() async throws {
        let archive = Data("tar-bytes-of-busybox".utf8)
        let server = try serving { request in
            switch (request.method, request.path) {
            case ("GET", "/images/busybox:1.36/json"), ("GET", "/images/hvfonly:1/json"):
                return (200, Self.json(["Id": "sha256:ab3f"]))
            case ("GET", "/images/busybox:1.36/get"): return (200, archive)
            case ("GET", "/images/get"): return (200, archive + Data("+more".utf8))
            case ("GET", "/images/missing:1/get"): return (404, Self.json(["message": "image export: not found"]))
            case ("POST", "/images/load"):
                return (200, Self.json(["stream": "unpacking docker.io/library/busybox:1.36 (sha256:73aa)...done\n"]))
            case ("GET", _) where request.path.hasPrefix("/images/"):
                return (404, Self.json(["message": "No such image"]))
            default: return (501, Self.json(["message": "unsupported image operation"]))
            }
        }
        let apple = RecordingImages()
        let router = ImageRouter(apple: apple, registry: try registry(hvf: true))
        let directory = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("busybox.tar")
        try Data("stale".utf8).write(to: output)

        try await router.save("busybox:1.36", to: output.path)
        XCTAssertEqual(try Data(contentsOf: output), archive, "the guest's archive replaces the file")
        try await router.saveAll(["busybox:1.36", "hvfonly:1"], to: output.path)
        XCTAssertEqual(try Data(contentsOf: output), archive + Data("+more".utf8))
        let multi = try XCTUnwrap(server.requests.last { $0.path == "/images/get" })
        XCTAssertEqual(multi.query["names"] != nil, true, "several images go in one /images/get?names=…")
        let mixed = await failure {
            try await router.saveAll(["busybox:1.36", "docker.io/library/alpine:3.20"], to: output.path)
        }
        XCTAssertEqual(mixed?.code, "failed_precondition", mixed?.message ?? "")
        XCTAssertTrue(mixed?.message.contains("several runtimes (apple, hvf)") ?? false, mixed?.message ?? "")

        let missing = await failure { try await router.save("missing:1", to: output.path, runtime: "hvf") }
        XCTAssertEqual(missing?.code, "not_found", missing?.message ?? "")
        XCTAssertEqual(try Data(contentsOf: output), archive + Data("+more".utf8), "a failed save keeps the old file")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path), ["busybox.tar"],
            "and leaves no partial archive")

        let input = directory.appendingPathComponent("in.tar")
        try archive.write(to: input)
        try await router.load(from: input.path, runtime: "hvf")
        let load = try XCTUnwrap(server.requests.last { $0.path == "/images/load" })
        XCTAssertEqual(load.method, "POST")
        XCTAssertEqual(load.body, archive, "the archive is the request body")
        XCTAssertEqual(load.headers["content-type"], "application/x-tar")
        XCTAssertEqual(load.headers["content-length"], String(archive.count))
        let reported = try await HVFImageStore(machine: HVFMachineClient(layout: layout, environment: [:]))
            .load(from: input.path)
        XCTAssertEqual(reported, "unpacking docker.io/library/busybox:1.36 (sha256:73aa)...done")

        try await router.save("docker.io/library/alpine:3.20", to: output.path)
        try await router.load(from: input.path)
        let calls = await apple.calls.filter { $0 != "list" }
        XCTAssertEqual(
            calls, ["save docker.io/library/alpine:3.20", "load \(input.path)"],
            "Apple's own images and unnamed loads stay Apple's (its listings answer ownership)")

        let notAFile = await failure { try await router.load(from: directory.path, runtime: "hvf") }
        XCTAssertEqual(notAFile?.code, "invalid_argument", notAFile?.message ?? "")
    }

    func testAnEngineDefaultLeavesBuildAndLoadOnApple() async throws {
        try serving(Self.guest)
        let apple = RecordingImages()
        let router = ImageRouter(apple: apple, registry: try registry(hvf: true, default: "hvf"))
        for try await _ in router.build(ContainerBuildRequest(contextDirectory: "ctx")) {}
        try await router.load(from: "/tmp/in.tar")
        for try await _ in router.pull("busybox:1.36", platform: nil) {}
        let calls = await apple.calls
        XCTAssertEqual(calls, ["build ctx", "load /tmp/in.tar"], "the pull went to hvf, the default")
    }

    func testAPIPullsOnAnEngineStopAtTheCallersDeadline() async throws {
        let slow = AsyncThrowingStream<ProgressEvent, Error> { continuation in
            let task = Task {
                try? await Task.sleep(for: .seconds(30))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        let started = ContinuousClock.now
        let failed = await failure {
            for try await _ in ImageRouter.bounded(slow, by: Date().addingTimeInterval(0.2), reference: "x") {}
        }
        XCTAssertEqual(failed?.code, "deadline_exceeded", failed?.message ?? "")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    // MARK: Docker wire

    func testDockerImageAndVolumeMapping() throws {
        let volume = DockerResources.volume(from: [
            "Name": "v", "Driver": "local", "Mountpoint": "/m", "CreatedAt": "t", "Labels": ["a": "b"],
            "UsageData": ["Size": 42, "RefCount": 1],
        ])
        XCTAssertEqual(volume.id, "v")
        XCTAssertEqual(volume.sizeBytes, 42)
        XCTAssertEqual(volume.labels, ["a": "b"])
        let image = DockerResources.image(from: [
            "Id": "sha256:1", "RepoTags": ["<none>:<none>"], "Created": 1_700_000_000.0, "Size": 0,
        ])
        XCTAssertEqual(image.names, [], "dangling images have no name")
        XCTAssertEqual(image.createdAt, "2023-11-14T22:13:20Z")
        XCTAssertEqual(image.variants, [], "Docker's listing names no platform")
        XCTAssertEqual(DockerResources.keyValues(["a=1", "b", "c=x=y"]), ["a": "1", "b": "", "c": "x=y"])
        XCTAssertEqual(DockerResources.splitTag("localhost:5000/app:1").repo, "localhost:5000/app")
        XCTAssertEqual(DockerResources.splitTag("localhost:5000/app:1").tag, "1")
        XCTAssertNil(DockerResources.splitTag("localhost:5000/app").tag, "a registry port is not a tag")
        XCTAssertNil(DockerResources.splitTag("app@sha256:abc").tag)
    }

    func testPullProgressLinesAndInStreamErrors() throws {
        var splitter = PullLineSplitter()
        XCTAssertEqual(splitter.feed(Data(#"{"status":"Pulling"}"#.utf8)), [])
        XCTAssertEqual(
            splitter.feed(Data("\n{\"id\":\"a1\",\"status\":\"Downloading\",\"progress\":\"[=> ]\"}\n{".utf8)).count, 2)
        XCTAssertEqual(splitter.flush(), "{")
        XCTAssertEqual(
            try DockerResources.progress(#"{"id":"a1","status":"Downloading","progress":"[=> ]"}"#).line,
            "a1 Downloading [=> ]")
        XCTAssertThrowsError(try DockerResources.progress(#"{"errorDetail":{"message":"denied"},"error":"denied"}"#)) {
            XCTAssertTrue($0.localizedDescription.contains("denied"))
        }
        XCTAssertEqual(try DockerResources.progress("not json").line, "not json")
    }

    func testDockerEngineStoresUseTheFullAPI() async throws {
        let path = "/tmp/mpd-\(UUID().uuidString.prefix(8)).sock"
        let server = try FakeDockerServer(path: path) { request in
            switch (request.method, request.path) {
            case ("POST", "/volumes/prune"):
                return (200, Self.json(["VolumesDeleted": ["a", "b"], "SpaceReclaimed": 10]))
            case ("POST", "/images/prune"): return (200, Self.json(["ImagesDeleted": [["Untagged": "x"]]]))
            case ("POST", "/images/alpine:3.20/tag"): return (201, Data())
            case ("DELETE", "/images/alpine:3.20"): return (200, Self.json([[String: String]()]))
            case ("POST", "/volumes/create"): return (201, Self.json(["Name": "v"]))
            default: return (404, Self.json(["message": "unexpected"]))
            }
        }
        defer { server.stop() }
        let engine = DockerEngine(endpoint: "unix://" + path, environment: ["DOCKER_API_VERSION": "1.44"])
        let volumes = try XCTUnwrap(engine.volumeStore)
        let images = try XCTUnwrap(engine.imageStore)
        let pruned = try await volumes.prune()
        XCTAssertEqual(pruned, "removed 2 volumes, reclaimed 10 bytes")
        let imagePrune = try await images.prune(danglingOnly: false)
        XCTAssertEqual(imagePrune, "removed 1 images, reclaimed 0 bytes")
        try await images.tag(source: "alpine:3.20", target: "registry:5000/me/alpine:mine")
        try await images.delete("alpine:3.20", force: true)
        try await volumes.create(name: "v", size: nil, labels: [], options: ["type=tmpfs"])
        let sized = await failure { try await volumes.create(name: "v", size: "1g", labels: [], options: []) }
        XCTAssertEqual(sized?.code, "unimplemented")
        let requests = server.requests
        XCTAssertEqual(requests[0].query, ["filters": #"{"all":["true"]}"#], "named volumes too, like Apple's prune")
        XCTAssertEqual(requests[1].query, ["filters": #"{"dangling":["false"]}"#])
        XCTAssertEqual(requests[2].query, ["repo": "registry:5000/me/alpine", "tag": "mine"])
        XCTAssertEqual(requests[3].query, ["force": "1"])
        let created = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[4].body) as? [String: Any])
        XCTAssertEqual(created["DriverOpts"] as? [String: String], ["type": "tmpfs"])
        XCTAssertEqual(requests.count, 5)
    }

    func testCapabilitiesAdvertiseOnlyWhatEachEngineDoes() {
        XCTAssertEqual(
            HVFEngine.supportedCapabilities.filter { ["volumes", "images"].contains($0) }, ["volumes", "images"])
        for capability in [
            ResourceCapability.imageRemove, ResourceCapability.imageTag, ResourceCapability.imagePush,
            ResourceCapability.imageSave, ResourceCapability.imageLoad, ResourceCapability.build,
            ResourceCapability.volumePrune, ResourceCapability.volumeClone,
        ] {
            XCTAssertFalse(HVFEngine.supportedCapabilities.contains(capability), "hvf: \(capability)")
        }
        let docker = DockerEngine(endpoint: "unix:///nonexistent.sock").capabilities
        XCTAssertTrue(docker.contains(ResourceCapability.volumePrune))
        XCTAssertFalse(docker.contains(ResourceCapability.imagePush), "push needs Docker's own credentials")
    }
}

// MARK: - Fakes

/// Apple's volume service, recording every call.
actor RecordingVolumes: VolumeServing {
    static let listing = [Micropod_V1_Volume.with { $0.id = "data" }]
    let names: [String]
    let failure: (any Error)?
    var calls: [String] = []

    init(names: [String] = ["data"], failure: (any Error)? = nil) {
        self.names = names
        self.failure = failure
    }

    func list() async throws -> [Micropod_V1_Volume] {
        calls.append("list")
        if let failure { throw failure }
        return names.map { name in Micropod_V1_Volume.with { $0.id = name } }
    }

    func create(name: String, size: String?, labels: [String], options: [String]) async throws {
        calls.append(
            "create \(name) size=\(size ?? "nil") labels=\(labels.joined(separator: ",")) "
                + "options=\(options.joined(separator: ","))")
    }

    func delete(_ name: String) async throws { calls.append("delete \(name)") }

    func prune() async throws -> String {
        calls.append("prune")
        return "apple pruned volumes"
    }

    func clone(source: String, name: String, size: String?, labels: [String]) async throws -> Micropod_V1_Volume {
        calls.append("clone \(source)->\(name)")
        return Micropod_V1_Volume.with { $0.id = name }
    }

    func commitClone(containerID: String, volume: String) async throws -> UInt64 {
        calls.append("commit \(containerID) \(volume)")
        return 1
    }
}

/// Apple's image service, recording every call.
actor RecordingImages: ImageServing {
    static let listing = [
        Micropod_V1_Image.with {
            $0.id = "apple-alpine"
            $0.names = ["docker.io/library/alpine:3.20"]
        }
    ]
    var calls: [String] = []

    private func record(_ call: String) { calls.append(call) }

    private nonisolated func recorded(_ call: String) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(call)
                continuation.yield(ProgressEvent(line: call))
                continuation.finish()
            }
        }
    }

    func list() async throws -> [Micropod_V1_Image] {
        calls.append("list")
        return Self.listing
    }

    nonisolated func pull(_ reference: String, platform: String?) -> AsyncThrowingStream<ProgressEvent, Error> {
        recorded("pull \(reference) platform=\(platform ?? "nil")")
    }

    nonisolated func push(_ reference: String, platform: String?) -> AsyncThrowingStream<ProgressEvent, Error> {
        recorded("push \(reference) platform=\(platform ?? "nil")")
    }

    nonisolated func build(_ request: ContainerBuildRequest) -> AsyncThrowingStream<ProgressEvent, Error> {
        recorded("build \(request.contextDirectory)")
    }

    func delete(_ reference: String, force: Bool) async throws { calls.append("delete \(reference) force=\(force)") }

    func prune(danglingOnly: Bool) async throws -> String {
        calls.append("prune dangling=\(danglingOnly)")
        return "apple pruned images"
    }

    func tag(source: String, target: String) async throws { calls.append("tag \(source)->\(target)") }
    func save(_ reference: String, to outputPath: String) async throws { calls.append("save \(reference)") }
    func saveAll(_ references: [String], to outputPath: String) async throws { calls.append("saveAll") }
    func load(from inputPath: String) async throws { calls.append("load \(inputPath)") }

    func inspect(_ reference: String) async throws -> Data {
        calls.append("inspect \(reference)")
        return Data()
    }
}
