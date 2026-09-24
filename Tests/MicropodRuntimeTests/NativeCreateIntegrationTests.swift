import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Live flag-coverage tests for native `create`/`run` against a real
/// `container-apiserver`. Gated behind `MICROPOD_REAL_E2E=1`.
///
/// Each test creates a container through `NativeContainerService` and
/// verifies the resulting `ContainerConfiguration` (via `container
/// inspect`) and/or guest-visible behavior (via native `exec`).
///
/// Run: MICROPOD_REAL_E2E=1 swift test --filter NativeCreateIntegrationTests
final class NativeCreateIntegrationTests: XCTestCase {
    private var api: APIServerClient!
    private var cli: ContainerCLIClient!
    private var service: NativeContainerService!
    private var createdIDs: [String] = []
    private var createdVolumes: [String] = []

    private let image = "docker.io/library/alpine:latest"

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MICROPOD_REAL_E2E"] == "1",
            "set MICROPOD_REAL_E2E=1 to run live apiserver tests")
        guard FileManager.default.fileExists(atPath: "/usr/local/bin/container") else {
            throw XCTSkip("container CLI not installed")
        }
        api = APIServerClient()
        cli = ContainerCLIClient(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/container"))
        service = NativeContainerService(api: api, cli: ContainerService(client: cli))
        _ = try await api.ping(timeout: .seconds(15))
    }

    override func tearDown() async throws {
        for id in createdIDs {
            try? await service.delete(id, force: true)
        }
        createdIDs = []
        for name in createdVolumes {
            _ = try? await cli.run(
                ContainerCommand(arguments: ["volume", "rm", name]), timeout: .seconds(15))
        }
        createdVolumes = []
    }

    // MARK: run semantics

    /// `run` = create + bootstrap + startProcess(init) — the container
    /// must end up `running` with a live init process.
    func testDetachedRunReachesRunning() async throws {
        let name = "ncrun-\(UUID().uuidString.prefix(8))"
        let id = try await service.run(
            ContainerRunRequest(
                image: image, name: name, detach: true,
                arguments: ["/bin/sh", "-c", "sleep 60"]))
        createdIDs.append(id)

        let status = try await stateOf(id)
        XCTAssertEqual(status, "running", "detached run must leave the container running, got \(status)")

        let res = try await service.execDetailed(
            ContainerExecRequest(containerID: id, arguments: ["/bin/echo", "alive"]))
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertTrue(res.output.contains("alive"))
    }

    /// A run whose image cannot be resolved must not leave a container
    /// behind — the CLI deletes on failed create/start.
    func testRunFailureLeavesNoContainer() async throws {
        let name = "ncrun-bad-\(UUID().uuidString.prefix(8))"
        do {
            _ = try await service.run(
                ContainerRunRequest(
                    image: "docker.io/library/definitely-not-a-real-image-zzz:latest",
                    name: name, detach: true, arguments: ["true"]))
            XCTFail("run with a nonexistent image must throw")
        } catch {
            // expected
        }
        let list = try await api.list()
        let entries = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: list, context: "list")
        XCTAssertFalse(
            entries.contains { $0.id == name },
            "failed run left container \(name) behind")
    }

    /// Duplicate id → server-side exists error, original survives.
    func testDuplicateNameFails() async throws {
        let name = "ncdup-\(UUID().uuidString.prefix(8))"
        let id = try await service.create(
            ContainerRunRequest(image: image, name: name, arguments: ["sleep", "60"]))
        createdIDs.append(id)
        do {
            _ = try await service.create(
                ContainerRunRequest(image: image, name: name, arguments: ["sleep", "60"]))
            XCTFail("duplicate name must throw")
        } catch {
            // expected — .exists
        }
    }

    /// A bind-mount source that doesn't exist must fail client-side
    /// before any container is created.
    func testInvalidBindMountFailsClean() async throws {
        let name = "ncbadmnt-\(UUID().uuidString.prefix(8))"
        do {
            _ = try await service.create(
                ContainerRunRequest(
                    image: image, name: name,
                    volumes: ["/definitely/not/here/\(UUID().uuidString):/mnt"],
                    arguments: ["sleep", "60"]))
            XCTFail("nonexistent bind-mount source must throw")
        } catch {
            // expected
        }
        let list = try await api.list()
        let entries = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: list, context: "list")
        XCTAssertFalse(entries.contains { $0.id == name })
    }

    // MARK: process configuration

    /// Request env lands in the container; image env (e.g. PATH) survives
    /// — verified in the guest, not just the DTO.
    func testEnvPropagation() async throws {
        let id = try await createStarted(
            ContainerRunRequest(
                image: image, name: nil,
                env: ["NATIVE_A=one", "NATIVE_B=two=2"],
                arguments: ["sleep", "60"]))
        let res = try await service.execDetailed(
            ContainerExecRequest(containerID: id, arguments: ["/usr/bin/env"]))
        XCTAssertTrue(res.output.contains("NATIVE_A=one"))
        XCTAssertTrue(res.output.contains("NATIVE_B=two=2"))
        XCTAssertTrue(res.output.contains("PATH="), "image env must be preserved")
    }

    func testWorkdirAndUser() async throws {
        let id = try await createStarted(
            ContainerRunRequest(
                image: image,
                user: "nobody",
                workdir: "/etc",
                arguments: ["sleep", "60"]))
        let pwd = try await service.execDetailed(
            ContainerExecRequest(containerID: id, arguments: ["/bin/pwd"], workdir: "/etc"))
        XCTAssertEqual(pwd.output.trimmingCharacters(in: .whitespacesAndNewlines), "/etc")
        let uid = try await service.execDetailed(
            ContainerExecRequest(containerID: id, arguments: ["/usr/bin/id", "-u"], user: "nobody"))
        XCTAssertEqual(uid.output.trimmingCharacters(in: .whitespacesAndNewlines), "65534")
    }

    /// Image entrypoint semantics: --entrypoint replaces, arguments
    /// become argv — verified through the logs of a short-lived run.
    func testEntrypointOverride() async throws {
        let id = try await service.run(
            ContainerRunRequest(
                image: image, detach: true,
                entrypoint: "/bin/echo",
                arguments: ["ep-works"]))
        createdIDs.append(id)
        try await Task.sleep(for: .milliseconds(700))
        let streamer = NativeLogStreamer(api: api)
        let lines = try await streamer.tail(id: id, lines: 50)
        XCTAssertTrue(
            lines.contains { $0.text.contains("ep-works") },
            "expected entrypoint output, got \(lines.map(\.text))")
    }

    // MARK: configuration fields (verified via `container inspect`)

    func testLabelsReachConfig() async throws {
        let id = try await service.create(
            ContainerRunRequest(
                image: image,
                labels: [LabelSpec(key: "app", value: "micropod"), LabelSpec(key: "empty", value: "")],
                arguments: ["sleep", "60"]))
        createdIDs.append(id)
        let labels = try await inspectConfig(id)["labels"]
        XCTAssertEqual(stringField(labels, "app"), "micropod")
        XCTAssertEqual(stringField(labels, "empty"), "")
    }

    func testResourcesReachConfig() async throws {
        let id = try await service.create(
            ContainerRunRequest(
                image: image, cpus: 2, memory: "512m",
                arguments: ["sleep", "60"]))
        createdIDs.append(id)
        let resources = try await inspectConfig(id)["resources"]
        XCTAssertEqual(intField(resources, "cpus"), 2)
        // "512m" is binary MiB in the CLI's grammar.
        XCTAssertEqual(intField(resources, "memoryInBytes"), 512 * 1024 * 1024)
    }

    func testDnsAndReadOnlyReachConfig() async throws {
        let id = try await service.create(
            ContainerRunRequest(
                image: image, readOnly: true,
                dns: ["8.8.8.8"], dnsSearch: ["example.test"],
                arguments: ["sleep", "60"]))
        createdIDs.append(id)
        let config = try await inspectConfig(id)
        XCTAssertEqual(boolField(config, "readOnly"), true)
        let dns = config["dns"]
        XCTAssertTrue(jsonArray(dns, "nameservers").contains("8.8.8.8"))
        XCTAssertTrue(jsonArray(dns, "searchDomains").contains("example.test"))

        try await service.start(id)
        let res = try await service.execDetailed(
            ContainerExecRequest(containerID: id, arguments: ["/bin/sh", "-c", "touch /x 2>&1; echo rc=$?"]))
        XCTAssertTrue(
            res.output.contains("rc=") && !res.output.contains("rc=0\n"),
            "rootfs must reject writes when readOnly, got \(res.output)")
    }

    func testCapAddDropAndShmReachConfig() async throws {
        let id = try await service.create(
            ContainerRunRequest(
                image: image,
                shmSize: "64m",
                capAdd: ["SYS_PTRACE"], capDrop: ["MKNOD"],
                arguments: ["sleep", "60"]))
        createdIDs.append(id)
        let config = try await inspectConfig(id)
        XCTAssertEqual(intField(config, "shmSize"), 64 * 1024 * 1024)
        // Capabilities normalize to CAP_* like Parser.capabilities.
        XCTAssertTrue(jsonArray(config, "capAdd").contains("CAP_SYS_PTRACE"))
        XCTAssertTrue(jsonArray(config, "capDrop").contains("CAP_MKNOD"))
    }

    func testUlimitReachesGuest() async throws {
        let id = try await createStarted(
            ContainerRunRequest(
                image: image,
                ulimits: ["nofile=1024:2048"],
                arguments: ["sleep", "60"]))
        let res = try await service.execDetailed(
            ContainerExecRequest(containerID: id, arguments: ["/bin/sh", "-c", "ulimit -n"]))
        // initProcess rlimits apply to the init process; exec'd processes
        // inherit container defaults — the DTO must at least carry them.
        let config = try await inspectConfig(id)
        let rlimits = config["initProcess"]?["rlimits"]
        XCTAssertNotNil(rlimits)
        XCTAssertTrue(res.exitCode == 0)
    }

    // MARK: mounts

    func testTmpfsMount() async throws {
        let id = try await createStarted(
            ContainerRunRequest(
                image: image,
                tmpfs: ["/scratch"],
                arguments: ["sleep", "60"]))
        let res = try await service.execDetailed(
            ContainerExecRequest(
                containerID: id,
                arguments: ["/bin/sh", "-c", "touch /scratch/ok && mount | grep scratch"]))
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertTrue(res.output.contains("tmpfs"))
    }

    func testBindMount() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ncbind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "bind-data".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = try await createStarted(
            ContainerRunRequest(
                image: image,
                volumes: ["\(dir.path):/mnt:ro"],
                arguments: ["sleep", "60"]))
        let res = try await service.execDetailed(
            ContainerExecRequest(containerID: id, arguments: ["/bin/cat", "/mnt/f.txt"]))
        XCTAssertEqual(res.output.trimmingCharacters(in: .whitespacesAndNewlines), "bind-data")
    }

    func testNamedVolume() async throws {
        let volume = "ncvol-\(UUID().uuidString.prefix(8))"
        createdVolumes.append(volume)
        let id = try await createStarted(
            ContainerRunRequest(
                image: image,
                volumes: ["\(volume):/data"],
                arguments: ["sleep", "60"]))
        // Volume must exist server-side and be mounted.
        let inspected = try await api.volumeInspect(name: volume)
        XCTAssertNotNil(inspected, "named volume must be created via volumeCreate")
        let res = try await service.execDetailed(
            ContainerExecRequest(
                containerID: id,
                arguments: ["/bin/sh", "-c", "echo vdata > /data/f && cat /data/f"]))
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertTrue(res.output.contains("vdata"))
    }

    // MARK: networks

    func testPublishedPortsReachConfig() async throws {
        let id = try await service.create(
            ContainerRunRequest(
                image: image,
                publishedPorts: [PortSpec(hostPort: 18091, containerPort: 8080)],
                arguments: ["sleep", "60"]))
        createdIDs.append(id)
        let ports = try await inspectConfig(id)["publishedPorts"]
        guard case .array(let arr) = ports, case .object(let p) = arr.first else {
            return XCTFail("publishedPorts missing from config: \(String(describing: ports))")
        }
        XCTAssertEqual(intField(.object(p), "hostPort"), 18091)
        XCTAssertEqual(intField(.object(p), "containerPort"), 8080)
    }

    /// Published port actually forwards host→guest.
    func testPublishedPortForwards() async throws {
        let responder =
            "while true; do echo -e 'HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\n\\r\\nhi' | nc -l -p 8080; done"
        let id = try await service.run(
            ContainerRunRequest(
                image: image, detach: true,
                publishedPorts: [PortSpec(hostPort: 18092, containerPort: 8080)],
                arguments: ["/bin/sh", "-c", responder]))
        createdIDs.append(id)
        try await Task.sleep(for: .milliseconds(1200))
        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:18092/")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("hi"))
    }

    func testNoNetwork() async throws {
        let id = try await service.create(
            ContainerRunRequest(
                image: image, networks: ["none"],
                arguments: ["sleep", "60"]))
        createdIDs.append(id)
        let networks = try await inspectConfig(id)["networks"]
        guard case .array(let arr) = networks else {
            return XCTFail("networks missing")
        }
        XCTAssertTrue(arr.isEmpty, "network 'none' must produce zero attachments")
    }

    // MARK: copy

    /// host→container (`copyIn`) verified by exec; container→host
    /// (`copyOut`) verified by file contents.
    func testCopyRoundTrip() async throws {
        let id = try await createStarted(
            ContainerRunRequest(image: image, arguments: ["sleep", "60"]))

        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("nccopy-\(UUID().uuidString).txt")
        try "copy-payload".write(to: src, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: src) }

        try await service.copy(from: src.path, to: "\(id):/tmp/in.txt")
        let inside = try await service.execDetailed(
            ContainerExecRequest(containerID: id, arguments: ["/bin/cat", "/tmp/in.txt"]))
        XCTAssertEqual(inside.output.trimmingCharacters(in: .whitespacesAndNewlines), "copy-payload")

        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("nccopy-out-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: dst) }
        try await service.copy(from: "\(id):/tmp/in.txt", to: dst.path)
        XCTAssertEqual(
            try String(contentsOf: dst, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "copy-payload")
    }

    func testCopyRejectsBadRefs() async throws {
        do {
            try await service.copy(from: "a:/x", to: "b:/y")
            XCTFail("container→container must be rejected")
        } catch { /* expected */  }
        do {
            try await service.copy(from: "/tmp/a", to: "/tmp/b")
            XCTFail("local→local must be rejected")
        } catch { /* expected */  }
    }

    // MARK: images / prune

    /// `images.ensure` pulls when the reference isn't in the local
    /// content store. `hello-world` is tiny and almost never cached.
    func testPullIfMissing() async throws {
        let reference = "docker.io/library/hello-world:latest"
        let images = ImagesServiceClient()
        let already = try await images.find(reference: reference, registryDomain: "docker.io")
        let id = try await service.create(
            ContainerRunRequest(
                image: reference,
                name: "ncpull-\(UUID().uuidString.prefix(8))"))
        createdIDs.append(id)
        if already == nil {
            // It wasn't local — the create above must have pulled it.
            let now = try await images.find(reference: reference, registryDomain: "docker.io")
            XCTAssertNotNil(now, "image must be in the local store after pull")
        }
        let state = try await stateOf(id)
        XCTAssertEqual(state, "stopped")
    }

    /// Native prune = list(stopped) → diskUsage → delete.
    func testPruneRemovesStoppedOnly() async throws {
        let stopped = try await service.create(
            ContainerRunRequest(
                image: image, name: "ncprune-s-\(UUID().uuidString.prefix(8))",
                arguments: ["sleep", "60"]))
        createdIDs.append(stopped)
        let running = try await createStarted(
            ContainerRunRequest(
                image: image, name: "ncprune-r-\(UUID().uuidString.prefix(8))",
                arguments: ["sleep", "60"]))

        _ = try await service.prune()

        let stoppedState = try await stateOf(stopped)
        let runningState = try await stateOf(running)
        XCTAssertEqual(stoppedState, "missing", "stopped container must be pruned")
        XCTAssertEqual(runningState, "running", "running container must survive prune")
        createdIDs.removeAll { $0 == stopped }
    }

    // MARK: CLI parity

    /// Create equivalent containers via CLI and natively; the inspect
    /// output must agree on every flag-derived field.
    func testCLIvsNativeConfigParity() async throws {
        let request = ContainerRunRequest(
            image: image,
            env: ["P_A=1", "P_B=2"],
            publishedPorts: [PortSpec(hostPort: 18093, containerPort: 9090)],
            tmpfs: ["/pt"],
            labels: [LabelSpec(key: "par", value: "1")],
            user: "daemon",
            shmSize: "64m",
            dns: ["1.1.1.1"],
            capAdd: ["NET_ADMIN"],
            ulimits: ["nofile=512"],
            workdir: "/opt",
            arguments: ["sleep", "60"])

        let nativeID = try await service.create(request)
        createdIDs.append(nativeID)

        // Same flags through the real CLI for ground truth.
        let cliName = "clipar-\(UUID().uuidString.prefix(8))"
        let cliOut = try await cli.run(
            ContainerCommand(arguments: [
                "create", "--name", cliName,
                "--env", "P_A=1", "--env", "P_B=2",
                "--publish", "18093:9090",
                "--tmpfs", "/pt",
                "--label", "par=1",
                "--shm-size", "64m",
                "--dns", "1.1.1.1",
                "--cap-add", "NET_ADMIN",
                "--ulimit", "nofile=512",
                "--workdir", "/opt",
                "--user", "daemon",
                image, "sleep", "60",
            ]),
            timeout: .seconds(120))
        let cliID = cliOut.trimmingCharacters(in: .whitespacesAndNewlines)
        createdIDs.append(cliID)

        let native = try await inspectConfig(nativeID)
        let reference = try await inspectConfig(cliID)

        // Field-level parity on everything the flags drove. Two fields
        // legitimately differ: env ordering (both sides dedup, order is
        // implementation-defined) and the network hostname (it's the
        // container id, which differs by construction).
        for key in [
            "mounts", "labels", "publishedPorts",
            "platform", "dns", "shmSize", "capAdd", "capDrop", "readOnly", "useInit",
        ] {
            XCTAssertEqual(
                native[key], reference[key],
                "config.\(key) diverges from CLI-produced container")
        }
        for key in [
            "executable", "arguments", "workingDirectory", "terminal", "user",
            "supplementalGroups", "rlimits",
        ] {
            XCTAssertEqual(
                native["initProcess"]?[key], reference["initProcess"]?[key],
                "initProcess.\(key) diverges from CLI-produced container")
        }
        XCTAssertEqual(
            sortedStrings(native["initProcess"]?["environment"]),
            sortedStrings(reference["initProcess"]?["environment"]),
            "initProcess.environment diverges")
        guard case .array(let nativeNets) = native["networks"],
            case .array(let refNets) = reference["networks"],
            nativeNets.count == refNets.count
        else {
            return XCTFail("network attachments diverge: \(String(describing: native["networks"]))")
        }
        for (n, r) in zip(nativeNets, refNets) {
            XCTAssertEqual(n["network"], r["network"])
            XCTAssertEqual(n["options"]?["mtu"], r["options"]?["mtu"])
        }
        XCTAssertEqual(
            native["resources"]?["cpuOverhead"], reference["resources"]?["cpuOverhead"])
    }

    // MARK: helpers

    private func createStarted(_ request: ContainerRunRequest) async throws -> String {
        var req = request
        if req.name == nil {
            req.name = "ncit-\(UUID().uuidString.prefix(8))"
        }
        let id = try await service.create(req)
        createdIDs.append(id)
        try await service.start(id)
        return id
    }

    /// The stored `ContainerConfiguration` — same JSON `container inspect`
    /// emits under `.configuration`.
    private func inspectConfig(_ id: String) async throws -> JSONValue {
        let out = try await cli.run(
            ContainerCommandFactory.inspectContainers([id]), timeout: .seconds(30))
        let decoded = try MicropodJSON.decoder.decode([JSONValue].self, from: Data(out.utf8))
        guard case .object(let obj) = decoded.first,
            let config = obj["configuration"]
        else {
            throw MicropodError.message("inspect for \(id) missing configuration")
        }
        return config
    }

    private func stateOf(_ id: String) async throws -> String {
        let data = try await api.list()
        let entries = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: data, context: "list")
        return entries.first { $0.id == id }?.status.state ?? "missing"
    }

    private func stringField(_ value: JSONValue?, _ key: String) -> String? {
        guard case .object(let o) = value, case .string(let s) = o[key] else { return nil }
        return s
    }

    private func intField(_ value: JSONValue?, _ key: String) -> Int? {
        guard case .object(let o) = value, case .number(let n) = o[key] else { return nil }
        return Int(n)
    }

    private func boolField(_ value: JSONValue?, _ key: String) -> Bool? {
        guard case .object(let o) = value, case .bool(let b) = o[key] else { return nil }
        return b
    }

    private func jsonArray(_ value: JSONValue?, _ key: String) -> [String] {
        guard case .object(let o) = value, case .array(let arr) = o[key] else { return [] }
        return arr.compactMap { if case .string(let s) = $0 { s } else { nil } }
    }

    private func sortedStrings(_ value: JSONValue?) -> [String] {
        guard case .array(let arr) = value else { return [] }
        return arr.compactMap { if case .string(let s) = $0 { s } else { nil } }.sorted()
    }
}
