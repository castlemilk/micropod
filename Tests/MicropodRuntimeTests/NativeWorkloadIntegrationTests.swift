import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Live workload tests: real images doing real work through the native
/// backend, plus concurrency and edge-case coverage beyond the
/// flag-parity suite. Gated on `MICROPOD_REAL_E2E=1`.
///
/// Run: MICROPOD_REAL_E2E=1 swift test --filter NativeWorkloadIntegrationTests
final class NativeWorkloadIntegrationTests: XCTestCase {
    private var api: APIServerClient!
    private var cli: ContainerCLIClient!
    private var service: NativeContainerService!
    private var createdIDs: [String] = []
    private var createdVolumes: [String] = []

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
        for vol in createdVolumes {
            _ = try? await cli.run(
                ContainerCommandFactory.deleteVolume(vol), timeout: .seconds(15))
        }
        createdVolumes = []
    }

    // MARK: real images

    /// postgres:16-alpine exercises ENTRYPOINT+CMD merge, env-driven init,
    /// and a real daemon — the heaviest realistic image locally cached.
    func testPostgresRealWorkload() async throws {
        let id = try await service.run(
            ContainerRunRequest(
                image: "docker.io/library/postgres:16-alpine",
                name: "nwpg-\(UUID().uuidString.prefix(8))",
                detach: true,
                env: ["POSTGRES_PASSWORD=bench", "POSTGRES_DB=benchdb"],
                arguments: []))  // image CMD: postgres
        createdIDs.append(id)

        // initdb takes a few seconds; poll pg_isready up to ~30 s.
        var ready = false
        for _ in 0..<30 {
            let res = try? await service.execDetailed(
                ContainerExecRequest(
                    containerID: id,
                    arguments: ["pg_isready", "-U", "postgres"], user: "postgres"))
            if res?.output.contains("accepting connections") == true {
                ready = true
                break
            }
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertTrue(ready, "postgres never became ready")

        let query = try await service.execDetailed(
            ContainerExecRequest(
                containerID: id,
                arguments: ["psql", "-U", "postgres", "-d", "benchdb", "-tc", "select 42"],
                user: "postgres"))
        XCTAssertEqual(query.exitCode, 0)
        XCTAssertTrue(query.output.contains("42"))
    }

    /// nginx over a published port — the canonical Docker workflow.
    /// Pulls ~25 MB on first run if not cached.
    func testNginxServesHTTP() async throws {
        let port = 18100 + Int.random(in: 0..<400)
        let id = try await service.run(
            ContainerRunRequest(
                image: "docker.io/library/nginx:alpine",
                name: "nwngx-\(UUID().uuidString.prefix(8))",
                detach: true,
                publishedPorts: [PortSpec(hostPort: port, containerPort: 80)]))
        createdIDs.append(id)

        var body = ""
        var ok = false
        for _ in 0..<20 {
            if let (data, response) = try? await URLSession.shared.data(
                from: URL(string: "http://127.0.0.1:\(port)/")!),
                (response as? HTTPURLResponse)?.statusCode == 200
            {
                body = String(decoding: data, as: UTF8.self)
                ok = true
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertTrue(ok, "nginx never answered on host port \(port)")
        XCTAssertTrue(body.contains("nginx"), "expected nginx welcome page, got \(body.prefix(120))")
    }

    /// python http.server — real interpreted workload + port forward.
    func testPythonHTTPServer() async throws {
        let port = 18500 + Int.random(in: 0..<400)
        let id = try await service.run(
            ContainerRunRequest(
                image: "docker.io/library/python:3.12-alpine",
                name: "nwpy-\(UUID().uuidString.prefix(8))",
                detach: true,
                publishedPorts: [PortSpec(hostPort: port, containerPort: 8000)],
                arguments: ["python", "-m", "http.server", "8000"]))
        createdIDs.append(id)

        var ok = false
        for _ in 0..<20 {
            if let (_, response) = try? await URLSession.shared.data(
                from: URL(string: "http://127.0.0.1:\(port)/")!),
                (response as? HTTPURLResponse)?.statusCode == 200
            {
                ok = true
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertTrue(ok, "python http.server never answered on host port \(port)")
    }

    /// alpine/git ships with `git` as ENTRYPOINT — verifies the image
    /// entrypoint is honored when no explicit command is given.
    func testImageEntrypointImage() async throws {
        let id = try await service.run(
            ContainerRunRequest(
                image: "docker.io/alpine/git:latest",
                name: "nwgit-\(UUID().uuidString.prefix(8))",
                detach: true,
                arguments: ["--version"]))
        createdIDs.append(id)
        try await Task.sleep(for: .milliseconds(1200))
        let streamer = NativeLogStreamer(api: api)
        let lines = try await streamer.tail(id: id, lines: 20)
        XCTAssertTrue(
            lines.contains { $0.text.contains("git version") },
            "expected `git version` output via image entrypoint, got \(lines.map(\.text))")
    }

    // MARK: exec robustness

    /// stdout and stderr must stay on separate channels.
    func testStdoutStderrSeparation() async throws {
        let id = try await started()
        let res = try await service.execDetailed(
            ContainerExecRequest(
                containerID: id,
                arguments: ["/bin/sh", "-c", "echo to-out; echo to-err >&2"]))
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertTrue(res.output.contains("to-out"))
        XCTAssertFalse(res.output.contains("to-err"), "stderr leaked into stdout")
        XCTAssertTrue(res.error.contains("to-err"), "stderr channel empty: \(res.error)")
    }

    /// A multi-megabyte exec output must arrive complete — exercises the
    /// nonblocking drain under sustained data flow (not just quiet-tail).
    func testExecLargeOutput() async throws {
        let id = try await started()
        let res = try await service.execDetailed(
            ContainerExecRequest(
                containerID: id,
                arguments: ["/bin/sh", "-c", "seq 1 200000"]))
        XCTAssertEqual(res.exitCode, 0)
        let lines = res.output.split(separator: "\n")
        XCTAssertEqual(lines.count, 200_000, "expected 200k lines, got \(lines.count)")
        XCTAssertEqual(lines.last, "200000")
    }

    /// Concurrent execs against one container — the persistent XPC
    /// connection multiplexes; each must get its own pipes + exit code.
    func testConcurrentExecs() async throws {
        let id = try await started()
        let service = self.service!
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    let res = try await service.execDetailed(
                        ContainerExecRequest(
                            containerID: id,
                            arguments: ["/bin/sh", "-c", "echo worker-\(i); exit \(i)"]))
                    XCTAssertEqual(res.exitCode, Int32(i))
                    XCTAssertTrue(res.output.contains("worker-\(i)"))
                }
            }
            try await group.waitForAll()
        }
    }

    /// Full create→start→delete lifecycle under concurrency — three
    /// independent containers at once.
    func testConcurrentLifecycle() async throws {
        let service = self.service!
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<3 {
                group.addTask {
                    let id = try await service.run(
                        ContainerRunRequest(
                            image: "docker.io/library/alpine:latest",
                            name: "nwconc-\(i)-\(UUID().uuidString.prefix(6))",
                            detach: true,
                            arguments: ["sleep", "30"]))
                    defer { Task { try? await service.delete(id, force: true) } }
                    let res = try await service.execDetailed(
                        ContainerExecRequest(containerID: id, arguments: ["/bin/echo", "ok-\(i)"]))
                    XCTAssertTrue(res.output.contains("ok-\(i)"))
                    try await service.delete(id, force: true)
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: lifecycle edges

    /// A created-but-never-started container must sit in `stopped` and
    /// still start cleanly later.
    func testCreateThenStartLater() async throws {
        let id = try await service.create(
            ContainerRunRequest(
                image: "docker.io/library/alpine:latest",
                name: "nwlazy-\(UUID().uuidString.prefix(8))",
                arguments: ["sleep", "60"]))
        createdIDs.append(id)
        var state = try await stateOf(id)
        XCTAssertEqual(state, "stopped")
        try await service.start(id)
        state = try await stateOf(id)
        XCTAssertEqual(state, "running")
    }

    /// force-delete on a running container.
    func testForceDeleteRunning() async throws {
        let id = try await started()
        try await service.delete(id, force: true)
        let state = try await stateOf(id)
        XCTAssertEqual(state, "missing")
        createdIDs.removeAll { $0 == id }
    }

    /// Restart must preserve the configuration (env, mounts).
    func testRestartPreservesConfig() async throws {
        let id = try await started(
            ContainerRunRequest(
                image: "docker.io/library/alpine:latest",
                env: ["STICKY=yes"],
                arguments: ["sleep", "60"]))
        try await service.restart(id)
        let res = try await service.execDetailed(
            ContainerExecRequest(containerID: id, arguments: ["/usr/bin/env"]))
        XCTAssertTrue(res.output.contains("STICKY=yes"), "env lost across restart")
    }

    /// `--env-file` propagation through the native path.
    func testEnvFile() async throws {
        let envFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("nwenv-\(UUID().uuidString).env")
        try "EF_A=from-file\nEF_B=second\n# comment\n".write(
            to: envFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: envFile) }
        let id = try await started(
            ContainerRunRequest(
                image: "docker.io/library/alpine:latest",
                envFiles: [envFile.path],
                arguments: ["sleep", "60"]))
        let res = try await service.execDetailed(
            ContainerExecRequest(containerID: id, arguments: ["/usr/bin/env"]))
        XCTAssertTrue(res.output.contains("EF_A=from-file"))
        XCTAssertTrue(res.output.contains("EF_B=second"))
    }

    /// Insufficient memory must be rejected server-side (200 MiB floor)
    /// and leave nothing behind.
    func testInsufficientMemoryRejected() async throws {
        let name = "nwmemory-\(UUID().uuidString.prefix(8))"
        do {
            _ = try await service.create(
                ContainerRunRequest(
                    image: "docker.io/library/alpine:latest",
                    name: name, memory: "64m",
                    arguments: ["sleep", "60"]))
            XCTFail("64 MiB must be rejected (200 MiB floor)")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("memory")
                    || error.localizedDescription.contains("200"),
                "unexpected error: \(error)")
        }
        let state = try await stateOf(name)
        XCTAssertEqual(state, "missing")
    }

    /// A bogus network name must fail at create with nothing left over.
    func testInvalidNetworkRejected() async throws {
        let name = "nwnet-\(UUID().uuidString.prefix(8))"
        do {
            _ = try await service.create(
                ContainerRunRequest(
                    image: "docker.io/library/alpine:latest",
                    name: name, networks: ["definitely-not-a-network"],
                    arguments: ["sleep", "60"]))
            XCTFail("unknown network must be rejected")
        } catch { /* expected */  }
        let state = try await stateOf(name)
        XCTAssertEqual(state, "missing")
    }

    // MARK: cache-clone volumes

    /// `com.micropod.cache.clone` forks a golden volume per container via
    /// APFS clonefile: clones see golden content, writes stay isolated
    /// from the golden and from sibling clones, and the mount reaches the
    /// VM as a raw `.block` attach.
    func testCacheCloneIsolatesGolden() async throws {
        let golden = "nwgold\(UUID().uuidString.prefix(6).lowercased())"
        _ = try await api.getOrCreateVolume(name: golden)
        createdVolumes.append(golden)

        // Populate the golden through a directly-attached container.
        let seed = try await started(
            ContainerRunRequest(
                image: "docker.io/library/alpine:latest",
                volumes: ["\(golden):/cache"],
                arguments: ["sleep", "60"]))
        _ = try await service.execDetailed(
            ContainerExecRequest(
                containerID: seed,
                arguments: ["sh", "-c", "echo golden-data > /cache/seeded.txt"]))
        try await service.delete(seed, force: true)
        createdIDs.removeAll { $0 == seed }

        // Two clones of the same golden.
        var cloneIDs: [String] = []
        for _ in 0..<2 {
            cloneIDs.append(
                try await started(
                    ContainerRunRequest(
                        image: "docker.io/library/alpine:latest",
                        volumes: ["\(golden):/cache"],
                        labels: [LabelSpec(key: "com.micropod.cache.clone", value: golden)],
                        arguments: ["sleep", "60"])))
        }
        for (i, id) in cloneIDs.enumerated() {
            let read = try await service.execDetailed(
                ContainerExecRequest(containerID: id, arguments: ["cat", "/cache/seeded.txt"]))
            XCTAssertTrue(read.output.contains("golden-data"), "clone \(i) missing golden content")
            _ = try await service.exec(
                ContainerExecRequest(
                    containerID: id,
                    arguments: ["sh", "-c", "echo job-\(i) > /cache/job-\(i).txt"]))
        }

        // Cross-clone isolation.
        let ls0 = try await service.execDetailed(
            ContainerExecRequest(containerID: cloneIDs[0], arguments: ["ls", "/cache"]))
        XCTAssertTrue(ls0.output.contains("job-0.txt"))
        XCTAssertFalse(ls0.output.contains("job-1.txt"), "clone writes leaked between clones")

        // The golden itself is untouched.
        let check = try await started(
            ContainerRunRequest(
                image: "docker.io/library/alpine:latest",
                volumes: ["\(golden):/cache"],
                arguments: ["sleep", "60"]))
        let lsGolden = try await service.execDetailed(
            ContainerExecRequest(containerID: check, arguments: ["ls", "/cache"]))
        XCTAssertTrue(lsGolden.output.contains("seeded.txt"))
        XCTAssertFalse(lsGolden.output.contains("job-0.txt"), "clone write leaked into golden")
    }

    /// Cloned images live under volume-clones/<id>/ and are removed when
    /// the container is deleted.
    func testCacheCloneCleanupOnDelete() async throws {
        let golden = "nwgold\(UUID().uuidString.prefix(6).lowercased())"
        _ = try await api.getOrCreateVolume(name: golden)
        createdVolumes.append(golden)

        let id = try await started(
            ContainerRunRequest(
                image: "docker.io/library/alpine:latest",
                volumes: ["\(golden):/cache"],
                labels: [LabelSpec(key: "com.micropod.cache.clone", value: golden)],
                arguments: ["sleep", "60"]))
        let cloneDir = NativeContainerService.cloneRoot.appendingPathComponent(id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloneDir.path))

        try await service.delete(id, force: true)
        createdIDs.removeAll { $0 == id }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cloneDir.path),
            "clone dir survived container delete")
    }

    /// `com.micropod.volume.sync=nosync` reaches the stored mount config,
    /// and a cloned mount reports `sync: nosync` + `block` type by default.
    func testVolumeSyncAndCloneConfig() async throws {
        let golden = "nwgold\(UUID().uuidString.prefix(6).lowercased())"
        _ = try await api.getOrCreateVolume(name: golden)
        createdVolumes.append(golden)

        // Named volume + explicit nosync label.
        let named = "nwvol\(UUID().uuidString.prefix(6).lowercased())"
        _ = try await api.getOrCreateVolume(name: named)
        createdVolumes.append(named)
        let id = try await service.create(
            ContainerRunRequest(
                image: "docker.io/library/alpine:latest",
                name: "nwsync-\(UUID().uuidString.prefix(6).lowercased())",
                volumes: ["\(named):/data"],
                labels: [LabelSpec(key: "com.micropod.volume.sync", value: "nosync")],
                arguments: ["sleep", "60"]))
        createdIDs.append(id)
        var mounts = try await mountsOf(id)
        var vol = try XCTUnwrap(
            mounts.first { $0.destination == "/data" }, "no /data mount in config")
        XCTAssertEqual(vol.typeCase, "volume")
        XCTAssertEqual(vol.sync, "nosync")

        // Clone gets block type + nosync by default.
        let cid = try await service.create(
            ContainerRunRequest(
                image: "docker.io/library/alpine:latest",
                name: "nwsync-\(UUID().uuidString.prefix(6).lowercased())",
                volumes: ["\(golden):/cache"],
                labels: [LabelSpec(key: "com.micropod.cache.clone", value: golden)],
                arguments: ["sleep", "60"]))
        createdIDs.append(cid)
        mounts = try await mountsOf(cid)
        vol = try XCTUnwrap(mounts.first { $0.destination == "/cache" }, "no /cache mount")
        XCTAssertEqual(vol.typeCase, "block")
        XCTAssertEqual(vol.sync, "nosync")
    }

    /// Cloning a nonexistent golden must fail create with nothing left
    /// over — no container, no clone dir.
    func testCloneMissingGoldenFails() async throws {
        let name = "nwnogold-\(UUID().uuidString.prefix(6).lowercased())"
        do {
            _ = try await service.create(
                ContainerRunRequest(
                    image: "docker.io/library/alpine:latest",
                    name: name,
                    volumes: ["missing-\(UUID().uuidString.prefix(4)):/cache"],
                    labels: [LabelSpec(key: "com.micropod.cache.clone", value: "*")],
                    arguments: ["sleep", "60"]))
            XCTFail("cloning a missing golden must be rejected")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("not found"),
                "unexpected error: \(error)")
        }
        let state = try await stateOf(name)
        XCTAssertEqual(state, "missing")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: NativeContainerService.cloneRoot.appendingPathComponent(name).path))
    }

    /// A persisted-style policy (injected, as `VolumePolicyStore.load()`
    /// would return after a UI/API/MCP write) must drive mounts without
    /// any per-container labels — and `jobsOnly` must gate it.
    func testPolicyDrivesClonesWithoutLabels() async throws {
        let golden = "nwgold\(UUID().uuidString.prefix(6).lowercased())"
        _ = try await api.getOrCreateVolume(name: golden)
        createdVolumes.append(golden)

        // Policy: clone all named volumes → unlabeled create gets .block.
        let cloneAll = NativeContainerService(
            api: api, cli: ContainerService(client: cli),
            policy: { VolumePolicy(cloneMode: .all) })
        let id = try await cloneAll.create(
            ContainerRunRequest(
                image: "docker.io/library/alpine:latest",
                name: "nwpol-\(UUID().uuidString.prefix(6).lowercased())",
                volumes: ["\(golden):/cache"],
                arguments: ["sleep", "60"]))
        createdIDs.append(id)
        let mounts = try await mountsOf(id)
        let vol = try XCTUnwrap(mounts.first { $0.destination == "/cache" }, "no /cache mount")
        XCTAssertEqual(vol.typeCase, "block")
        XCTAssertEqual(vol.sync, "nosync")

        // Same policy + jobsOnly must NOT clone an unlabeled container.
        let jobsOnly = NativeContainerService(
            api: api, cli: ContainerService(client: cli),
            policy: { VolumePolicy(cloneMode: .all, jobsOnly: true) })
        let jid = try await jobsOnly.create(
            ContainerRunRequest(
                image: "docker.io/library/alpine:latest",
                name: "nwpol-\(UUID().uuidString.prefix(6).lowercased())",
                volumes: ["\(golden):/cache"],
                arguments: ["sleep", "60"]))
        createdIDs.append(jid)
        let joblessMounts = try await mountsOf(jid)
        let uncloned = try XCTUnwrap(
            joblessMounts.first { $0.destination == "/cache" }, "no /cache mount")
        XCTAssertEqual(uncloned.typeCase, "volume", "jobsOnly policy leaked to a non-job container")

        // …but applies to a job-labelled one.
        let jobID = try await jobsOnly.create(
            ContainerRunRequest(
                image: "docker.io/library/alpine:latest",
                name: "nwpol-\(UUID().uuidString.prefix(6).lowercased())",
                volumes: ["\(golden):/cache"],
                labels: [LabelSpec(key: "com.cuttlefish.job", value: "t")],
                arguments: ["sleep", "60"]))
        createdIDs.append(jobID)
        let jobMounts = try await mountsOf(jobID)
        let cloned = try XCTUnwrap(
            jobMounts.first { $0.destination == "/cache" }, "no /cache mount")
        XCTAssertEqual(cloned.typeCase, "block")
    }

    /// N concurrent creates cloning the same golden must each get their
    /// own `.block` source (no cross-talk) — exercises the clone path
    /// under races with the orphan sweep.
    func testConcurrentCloneCreates() async throws {
        let golden = "nwconc\(UUID().uuidString.prefix(6).lowercased())"
        _ = try await api.getOrCreateVolume(name: golden)
        createdVolumes.append(golden)

        let service = try XCTUnwrap(self.service)
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await service.create(
                        ContainerRunRequest(
                            image: "docker.io/library/alpine:latest",
                            name: "nwconc-\(UUID().uuidString.prefix(8).lowercased())",
                            volumes: ["\(golden):/cache"],
                            labels: [LabelSpec(key: "com.micropod.cache.clone", value: golden)],
                            arguments: ["sleep", "60"]))
                }
            }
            var ids: [String] = []
            for try await id in group { ids.append(id) }
            return ids
        }
        createdIDs.append(contentsOf: ids)
        XCTAssertEqual(ids.count, 4)

        var sources = Set<String>()
        for id in ids {
            let mounts = try await mountsOf(id)
            let vol = try XCTUnwrap(mounts.first { $0.destination == "/cache" })
            XCTAssertEqual(vol.typeCase, "block")
            XCTAssertTrue(
                vol.source.hasSuffix("/\(id)/\(golden).img"),
                "clone source '\(vol.source)' not under clone root for \(id)")
            XCTAssertTrue(sources.insert(vol.source).inserted, "two containers share a clone")
        }
    }

    /// Orphaned clone dirs are swept by prune once older than the grace
    /// window; fresh dirs (possible in-flight creates) are left alone.
    func testOrphanSweepRespectsGraceWindow() async throws {
        let root = NativeContainerService.cloneRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fresh = root.appendingPathComponent("orphan-fresh-\(UUID().uuidString.prefix(6))")
        let stale = root.appendingPathComponent("orphan-stale-\(UUID().uuidString.prefix(6))")
        for dir in [fresh, stale] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("g.img"))
        }
        defer {
            try? FileManager.default.removeItem(at: fresh)
            try? FileManager.default.removeItem(at: stale)
        }
        // Backdate the stale dir past the 60s grace window.
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)

        _ = try await service.prune()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fresh.path),
            "fresh clone dir swept — could race an in-flight create")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stale.path),
            "stale orphan clone dir survived prune")
    }

    // MARK: helpers

    private struct MountInfo {
        var destination: String
        var typeCase: String
        var source: String
        var sync: String?
    }

    /// Mounts from the stored `ContainerConfiguration` (same JSON
    /// `container inspect` emits under `.configuration`).
    private func mountsOf(_ id: String) async throws -> [MountInfo] {
        let data = try await service.inspect(id)
        let decoded = try MicropodJSON.decoder.decode([JSONValue].self, from: data)
        guard case .object(let obj) = decoded.first,
            case .object(let config) = obj["configuration"],
            case .array(let mounts) = config["mounts"]
        else { throw MicropodError.message("inspect for \(id) missing mounts") }
        return mounts.compactMap { mount in
            guard case .object(let m) = mount,
                case .string(let dst) = m["destination"],
                case .object(let type) = m["type"],
                let typeCase = type.keys.first, case .object(let fields) = type[typeCase]
            else { return nil }
            var sync: String?
            if case .object(let s) = fields["sync"] { sync = s.keys.first }
            var source = ""
            if case .string(let s) = m["source"] { source = s }
            return MountInfo(destination: dst, typeCase: typeCase, source: source, sync: sync)
        }
    }

    private func started(
        _ request: ContainerRunRequest = ContainerRunRequest(
            image: "docker.io/library/alpine:latest", arguments: ["sleep", "60"])
    ) async throws -> String {
        var req = request
        if req.name == nil {
            req.name = "nwit-\(UUID().uuidString.prefix(8))"
        }
        let id = try await service.create(req)
        createdIDs.append(id)
        try await service.start(id)
        return id
    }

    private func stateOf(_ id: String) async throws -> String {
        let data = try await api.list()
        let entries = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: data, context: "list")
        return entries.first { $0.id == id }?.status.state ?? "missing"
    }
}
