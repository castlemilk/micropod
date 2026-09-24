import MicropodCore
import XCTest

/// End-to-end tests against the REAL Apple `container` runtime.
///
/// Gated behind `MICROPOD_REAL_E2E=1` (see `task e2e-real`). Every resource
/// carries a per-run namespace; `cleanup()` force-deletes all containers,
/// volumes, networks and images the suite created, even on test failure.
/// Never prunes or touches anything outside the namespace.
final class RealRuntimeTests: XCTestCase {
    func testPullRunExecLogsStatsLifecycle() async throws {
        try await withRealHarness { harness in
            let image = "alpine:3.20"

            var events: [ProgressEvent] = []
            for try await event in harness.images.pull(image, platform: nil) {
                events.append(event)
            }
            XCTAssertFalse(events.isEmpty, "pull must stream progress")

            let id = try await harness.containers.run(
                ContainerRunRequest(
                    image: image,
                    name: harness.name("web"),
                    env: ["E2E=1", "GREETING=hello"],
                    labels: [LabelSpec(key: "micropod.e2e", value: "true")],
                    useInit: true,
                    arguments: ["sh", "-c", "echo boot-line; sleep 600"]))
            XCTAssertFalse(id.isEmpty, "run must return a container id")

            // Listing via the real list output (the DTO regression fixture path).
            let containers = try await harness.containers.list()
            let mine = containers.first { $0.id == id }
            XCTAssertNotNil(mine, "container must appear in list")
            XCTAssertEqual(mine?.state, "running")
            XCTAssertEqual(mine?.env.contains("E2E=1"), true)
            XCTAssertEqual(mine?.labels["micropod.e2e"], "true")

            // exec
            let output = try await harness.containers.exec(
                ContainerExecRequest(containerID: id, arguments: ["echo", "e2e-ok"]))
            XCTAssertTrue(output.contains("e2e-ok"), "exec output was \(output)")

            // logs (bounded tail) capture the init process stdout.
            let lines = try await harness.logs.tail(id: id, lines: 10)
            XCTAssertTrue(
                lines.contains { $0.text.contains("boot-line") },
                "logs must carry the init process output: \(lines.map(\.text))")

            // stats: our running container appears with resource usage
            let snapshot = try await harness.snapshotWithRetry()
            let stats = snapshot.containers.first { $0.id == id }
            XCTAssertNotNil(stats, "stats must include the running container")
            XCTAssertGreaterThan(stats?.memoryUsedBytes ?? 0, 0)

            // lifecycle
            try await harness.containers.stop(id)
            var afterStop = try await harness.containers.list()
            XCTAssertEqual(afterStop.first { $0.id == id }?.state, "stopped")
            try await harness.containers.start(id)
            afterStop = try await harness.containers.list()
            XCTAssertEqual(afterStop.first { $0.id == id }?.state, "running")
            try await harness.containers.restart(id)
            afterStop = try await harness.containers.list()
            XCTAssertEqual(afterStop.first { $0.id == id }?.state, "running", "restart leaves running")
            try await harness.containers.stop(id)
            try await harness.containers.delete(id, force: true)
            let afterDelete = try await harness.containers.list()
            XCTAssertNil(afterDelete.first { $0.id == id }, "container must be deleted")
        }
    }

    func testVolumeAndNetworkLifecycle() async throws {
        try await withRealHarness { harness in
            let volumeName = harness.name("data")
            try await harness.volumes.create(name: volumeName, size: "100M")
            let volumes = try await harness.volumes.list()
            let mine = volumes.first { $0.id == volumeName }
            XCTAssertNotNil(mine, "volume must appear in list")
            XCTAssertEqual(mine?.driver, "local")
            XCTAssertEqual(mine?.sizeBytes, 104_857_600, "100M volume size")

            let networkName = harness.name("net")
            try await harness.networks.create(
                name: networkName, internal: true, subnet: "10.77.0.0/24")
            let networks = try await harness.networks.list()
            let net = networks.first { $0.id == networkName }
            XCTAssertNotNil(net, "network must appear in list")
            XCTAssertEqual(net?.mode, "hostOnly", "real CLI reports hostOnly for --internal")
            XCTAssertEqual(net?.ipv4Subnet, "10.77.0.0/24")
            XCTAssertFalse(net?.builtin ?? true)

            // Disk usage tracks the volume we created.
            let usage = try await harness.system.diskUsage()
            XCTAssertGreaterThan(usage.volumes.sizeBytes, 0)
        }
    }

    func testBuildAndRunBuiltImage() async throws {
        try await withRealHarness { harness in
            let context = harness.stateDir.appendingPathComponent("build-context")
            try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
            try """
            FROM alpine:3.20
            RUN echo building > /build-output.txt
            CMD ["cat", "/build-output.txt"]
            """.write(
                to: context.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)

            let tag = "\(harness.namespace)/built:latest"
            var events: [ProgressEvent] = []
            for try await event in harness.images.build(
                ContainerBuildRequest(contextDirectory: context.path, tags: [tag])
            ) {
                events.append(event)
            }
            XCTAssertTrue(events.contains { $0.stage != nil }, "build must stream stages")
            XCTAssertTrue(
                events.contains { $0.stage == 1 && $0.totalStages == 2 },
                "BuildKit [linux/arm64 1/2] lines must parse: \(events.map(\.line).suffix(3))")
            XCTAssertTrue(
                events.contains { $0.line.contains("exporting") },
                "build must export the image")

            let images = try await harness.images.list()
            XCTAssertTrue(images.contains { $0.names.contains(tag) }, "built image must be listed")

            // Run the built image (detached so run() returns the real id).
            let id = try await harness.containers.run(
                ContainerRunRequest(image: tag, name: harness.name("built")))
            let exitLogs = try await harness.logs.tail(id: id, lines: 5)
            XCTAssertTrue(
                exitLogs.contains { $0.text.contains("building") },
                "built image must run its CMD: \(exitLogs.map(\.text))")

            // The container exits after CMD; clean up.
            try await harness.containers.delete(id, force: true)
        }
    }

    func testComposeUpDownEndToEnd() async throws {
        try await withRealHarness { harness in
            let composeURL = harness.stateDir.appendingPathComponent("docker-compose.yml")
            try """
            name: \(harness.namespace)
            services:
              web:
                image: alpine:3.20
                container_name: \(harness.namespace)-web
                command: ["sleep", "600"]
                healthcheck:
                  test: ["CMD", "true"]
              db:
                image: alpine:3.20
                container_name: \(harness.namespace)-db
                command: ["sleep", "600"]
                depends_on:
                  web:
                    condition: service_healthy
                volumes:
                  - \(harness.namespace)-pgdata:/var/lib/postgresql/data
            volumes:
              \(harness.namespace)-pgdata:
            networks:
              \(harness.namespace)-front:
            """.write(to: composeURL, atomically: true, encoding: .utf8)

            let spec = try await harness.compose.parse(url: composeURL)
            XCTAssertEqual(spec.name, harness.namespace)
            let plan = try harness.compose.plan(spec: spec)
            XCTAssertEqual(plan.createdNetworks, ["\(harness.namespace)-front"])
            XCTAssertEqual(plan.createdVolumes, ["\(harness.namespace)-pgdata"])

            var progress: [String] = []
            for try await line in await harness.compose.up(plan: plan) {
                progress.append(line)
            }
            XCTAssertTrue(progress.contains("Network \(harness.namespace)-front created"))
            XCTAssertTrue(progress.contains("Volume \(harness.namespace)-pgdata created"))
            XCTAssertTrue(progress.contains("Started \(harness.namespace)-web"))
            XCTAssertTrue(progress.contains("Started \(harness.namespace)-db"))
            XCTAssertTrue(
                progress.contains("\(harness.namespace)-web is ready"),
                "service_healthy dependency must probe: \(progress)")

            let containers = try await harness.containers.list()
            let composeContainers = containers.filter {
                $0.labels["com.skunkworq.micropod.compose"] == harness.namespace
            }
            XCTAssertEqual(composeContainers.count, 2)
            XCTAssertEqual(Set(composeContainers.map(\.state)), ["running"])

            let volumes = try await harness.volumes.list()
            XCTAssertTrue(volumes.contains { $0.id == "\(harness.namespace)-pgdata" })
            let networks = try await harness.networks.list()
            XCTAssertTrue(networks.contains { $0.id == "\(harness.namespace)-front" })

            // Tear down and verify everything is removed.
            try await harness.compose.down(composeName: harness.namespace)

            let after = try await harness.containers.list()
            XCTAssertNil(
                after.first { $0.labels["com.skunkworq.micropod.compose"] == harness.namespace },
                "compose containers must be removed on down")
        }
    }

    // MARK: - Harness

    func testFullRunFlagsRoundTrip() async throws {
        try await withRealHarness { harness in
            let id = try await harness.containers.run(
                ContainerRunRequest(
                    image: "alpine:3.20",
                    name: harness.name("flags"),
                    env: ["FLAG=set"],
                    tmpfs: ["/scratch"],
                    labels: [LabelSpec(key: "micropod.flag", value: "yes")],
                    useInit: true,
                    readOnly: true,
                    user: "1000:1000",
                    dns: ["8.8.8.8"],
                    dnsSearch: ["example.com"],
                    capAdd: ["CAP_NET_RAW"],
                    capDrop: ["CAP_SYS_ADMIN"],
                    arguments: ["sleep", "60"]))
            try await Task.sleep(for: .seconds(2))

            // The raw inspect JSON must reflect every flag. The CLI pretty-prints,
            // so normalize before matching.
            let raw = try await harness.containers.inspect(id)
            let object = try JSONSerialization.jsonObject(with: raw)
            let compact = try JSONSerialization.data(withJSONObject: object)
            let json = String(data: compact, encoding: .utf8) ?? ""
            XCTAssertTrue(json.contains("\"capAdd\":[\"CAP_NET_RAW\"]"), "capAdd in inspect")
            XCTAssertTrue(json.contains("\"capDrop\":[\"CAP_SYS_ADMIN\"]"), "capDrop in inspect")
            XCTAssertTrue(json.contains("\"nameservers\":[\"8.8.8.8\"]"), "dns in inspect")
            XCTAssertTrue(json.contains("\"searchDomains\":[\"example.com\"]"), "dns search in inspect")
            XCTAssertTrue(json.contains("\"readOnly\":true"), "readOnly in inspect")
            XCTAssertTrue(json.contains("\"useInit\":true"), "useInit in inspect")
            XCTAssertTrue(json.contains("\"userString\":\"1000:1000\""), "user in inspect")
            XCTAssertTrue(
                json.contains("\"source\":\"tmpfs\""), "tmpfs mount in inspect (JSONSerialization re-escapes /)")

            // The typed mapping path.
            let mapped = try await harness.containers.list()
            let mine = mapped.first { $0.id == id }
            XCTAssertEqual(mine?.labels["micropod.flag"], "yes")
            XCTAssertTrue(mine?.readOnly ?? false)
            XCTAssertTrue(mine?.useInit ?? false)

            // Exec with workdir + env.
            let pwd = try await harness.containers.exec(
                ContainerExecRequest(
                    containerID: id, arguments: ["/bin/sh", "-c", "echo $E2E_VAR && pwd"],
                    workdir: "/tmp", env: ["E2E_VAR=42"]))
            XCTAssertTrue(pwd.contains("42"), "exec env: \(pwd)")
            XCTAssertTrue(pwd.contains("/tmp"), "exec workdir: \(pwd)")

            // Copy/export run on a plain container: the Apple runtime hangs
            // `container copy` on tmpfs-mounted paths (v1.2.2 quirk).
            let copier = try await harness.containers.run(
                ContainerRunRequest(
                    image: "alpine:3.20",
                    name: harness.name("copier"),
                    arguments: ["sh", "-c", "echo payload > /tmp/out.txt; sleep 60"]))
            try await Task.sleep(for: .seconds(2))
            let dest = harness.stateDir.appendingPathComponent("copied.txt")
            try await harness.containers.copy(from: "\(copier):/tmp/out.txt", to: dest.path)
            let copied = try String(contentsOf: dest, encoding: .utf8)
            XCTAssertEqual(copied.trimmingCharacters(in: .whitespacesAndNewlines), "payload")

            let tarball = harness.stateDir.appendingPathComponent("export.tar")
            try await harness.containers.export(copier, to: tarball.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: tarball.path))
            let size = (try? FileManager.default.attributesOfItem(atPath: tarball.path))?[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 1_000_000, "export should be a real rootfs tarball")
        }
    }

    func testKillAndExitCode() async throws {
        try await withRealHarness { harness in
            // A short-lived container transitions to stopped (run returns first).
            let exited = try await harness.containers.run(
                ContainerRunRequest(
                    image: "alpine:3.20", name: harness.name("exit"), arguments: ["sh", "-c", "exit 7"]))
            var mine = try await harness.containers.list().first { $0.id == exited }
            var waited = 0
            while mine?.state == "running", waited < 15 {
                try await Task.sleep(for: .milliseconds(500))
                mine = try await harness.containers.list().first { $0.id == exited }
                waited += 1
            }
            XCTAssertNotNil(mine, "exited container still listed")
            XCTAssertEqual(mine?.state, "stopped", "exited container reports stopped")
            try await harness.containers.delete(exited, force: true)

            // kill() marks the container killed.
            let victim = try await harness.containers.run(
                ContainerRunRequest(image: "alpine:3.20", name: harness.name("victim"), arguments: ["sleep", "300"]))
            try await Task.sleep(for: .seconds(2))
            try await harness.containers.kill(victim)
            let afterKill = try await harness.containers.list()
            XCTAssertEqual(
                afterKill.first { $0.id == victim }?.state, "stopped",
                "kill reports stopped on the real runtime")
            try await harness.containers.delete(victim, force: true)
        }
    }

    func testStatsCpuDeltaAcrossSamples() async throws {
        try await withRealHarness { harness in
            _ = try await harness.runAlive(name: "busy")
            try await Task.sleep(for: .seconds(2))

            let first = try await harness.snapshotWithRetry()
            let myStats = first.containers.first { $0.id.hasPrefix(harness.namespace) }
            XCTAssertNotNil(myStats, "stats must include our container")
            XCTAssertGreaterThan(myStats?.memoryUsedBytes ?? 0, 0)
            XCTAssertGreaterThan(myStats?.pids ?? 0, 0)

            try await Task.sleep(for: .milliseconds(300))
            let second = try await harness.snapshotWithRetry()
            let later = second.containers.first { $0.id.hasPrefix(harness.namespace) }
            XCTAssertNotNil(later?.cpuPercent, "second sample must compute a CPU delta")
            XCTAssertGreaterThanOrEqual(later?.cpuPercent ?? -1, 0)
        }
    }

    func testLogFollowStreamYieldsThenCancels() async throws {
        try await withRealHarness { harness in
            // The CLI only flushes the follow replay once fresh output arrives,
            // so the container must keep writing.
            let id = try await harness.containers.run(
                ContainerRunRequest(
                    image: "alpine:3.20",
                    name: harness.name("loggy"),
                    arguments: [
                        "sh", "-c",
                        "echo boot-line; i=0; while true; do echo tick-$i; i=$((i+1)); sleep 1; done",
                    ]))
            try await Task.sleep(for: .seconds(3))

            let stream = harness.logs.stream(id: id, tail: 10, boot: false)
            let streamTask = Task { () -> [String] in
                var collected: [String] = []
                for try await line in stream {
                    collected.append(line.text)
                }
                return collected
            }
            try await Task.sleep(for: .seconds(4))
            streamTask.cancel()
            let lines = try await streamTask.value
            XCTAssertTrue(
                lines.contains { $0.contains("boot-line") },
                "follow stream must replay buffered output: \(lines)")
            XCTAssertTrue(
                lines.contains { $0.contains("tick-") },
                "follow stream must carry live output: \(lines)")
        }
    }

    func testImageLifecyclePullTagSaveDelete() async throws {
        try await withRealHarness { harness in
            let namespaced = "\(harness.namespace)/tagged:1"
            try await harness.images.tag(source: "alpine:3.20", target: namespaced)
            let listed = try await harness.images.list()
            XCTAssertTrue(
                listed.contains { $0.names.contains { $0.hasSuffix("/\(namespaced)") } },
                "tag must appear (CLI normalizes to docker.io/): \(listed.map(\.names))")

            let tarball = harness.stateDir.appendingPathComponent("saved.tar")
            try await harness.images.save(namespaced, to: tarball.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: tarball.path))
            let size = (try? FileManager.default.attributesOfItem(atPath: tarball.path))?[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 100_000, "save should produce a real tarball")

            let inspected = try await harness.images.inspect(namespaced)
            guard
                let inspectedJSON = try JSONSerialization.jsonObject(with: inspected) as? [[String: Any]],
                let inspectedConfig = inspectedJSON.first?["configuration"] as? [String: Any],
                let inspectedName = inspectedConfig["name"] as? String
            else {
                return XCTFail("inspect must return a configuration.name")
            }
            XCTAssertTrue(
                inspectedName.hasSuffix("/\(namespaced)"),
                "inspect normalizes to docker.io/<ref>: \(inspectedName)")

            try await harness.images.delete(namespaced, force: true)
            let after = try await harness.images.list()
            XCTAssertFalse(after.contains { $0.names.contains(namespaced) }, "namespaced tag removed")
        }
    }

    func testVolumeWithLabelsAndSize() async throws {
        try await withRealHarness { harness in
            let name = harness.name("labelled")
            try await harness.volumes.create(
                name: name, size: "64M", labels: ["micropod.e2e=true"], options: [])
            let volumes = try await harness.volumes.list()
            let mine = volumes.first { $0.id == name }
            XCTAssertNotNil(mine)
            XCTAssertEqual(mine?.labels["micropod.e2e"], "true")
            XCTAssertEqual(mine?.sizeBytes, 67_108_864, "64M volume size")
        }
    }

    func testNetworkWithSubnetAndLabels() async throws {
        try await withRealHarness { harness in
            let name = harness.name("subnet")
            try await harness.networks.create(
                name: name, internal: true, subnet: "10.44.0.0/24", options: [], labels: ["micropod.e2e=net"])
            let networks = try await harness.networks.list()
            let mine = networks.first { $0.id == name }
            XCTAssertNotNil(mine)
            XCTAssertEqual(mine?.mode, "hostOnly")
            XCTAssertEqual(mine?.ipv4Subnet, "10.44.0.0/24")
            XCTAssertEqual(mine?.labels["micropod.e2e"], "net")
        }
    }

    func testCrossContainerConnectivity() async throws {
        try await withRealHarness { harness in
            let network = harness.name("net")
            try await harness.networks.create(name: network, subnet: "10.66.0.0/24")
            let a = try await harness.runAlive(name: "a", network: network)
            let b = try await harness.runAlive(name: "b", network: network)
            try await Task.sleep(for: .seconds(3))

            let containers = try await harness.containers.list()
            let bContainer = containers.first { $0.id == b }
            guard let bIP = bContainer?.ipv4Address, !bIP.isEmpty else {
                return XCTFail("container b must have an IP on the shared network: \(String(describing: bContainer))")
            }
            XCTAssertTrue(bIP.hasPrefix("10.66."), "IP must come from the compose subnet: \(bIP)")

            let result = try await harness.containers.exec(
                ContainerExecRequest(containerID: a, arguments: ["ping", "-c", "1", bIP]))
            XCTAssertTrue(result.contains("0% packet loss"), "L3 connectivity: \(result)")
        }
    }

    func testBuildWithArgsAndTargetStage() async throws {
        try await withRealHarness { harness in
            let context = harness.stateDir.appendingPathComponent("stages")
            try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
            try """
            FROM alpine:3.20 AS builder
            ARG VERSION
            RUN echo "version-$VERSION" > /version.txt
            FROM alpine:3.20 AS runtime
            COPY --from=builder /version.txt /version.txt
            CMD ["cat", "/version.txt"]
            """.write(
                to: context.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)

            let tag = "\(harness.namespace)/staged:latest"
            for try await _ in harness.images.build(
                ContainerBuildRequest(
                    contextDirectory: context.path,
                    tags: [tag],
                    buildArgs: ["VERSION=9"],
                    target: "runtime")
            ) {}

            let id = try await harness.containers.run(
                ContainerRunRequest(image: tag, name: harness.name("staged")))
            let logs = try await harness.logs.tail(id: id, lines: 5)
            XCTAssertTrue(
                logs.contains { $0.text.contains("version-9") },
                "build args + target must produce the right image: \(logs.map(\.text))")
            try await harness.containers.delete(id, force: true)
        }
    }

    func testComposeFullSurface() async throws {
        let hostPort = try ephemeralTCPPort()
        try await withRealHarness { harness in
            try "MODE=full\n".write(
                to: harness.stateDir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
            try "FROM_FILE=envfile-value\n".write(
                to: harness.stateDir.appendingPathComponent("svc.env"), atomically: true, encoding: .utf8)
            let composeURL = harness.stateDir.appendingPathComponent("docker-compose.yml")
            try """
            name: \(harness.namespace)
            services:
              api:
                image: alpine:3.20
                container_name: \(harness.namespace)-api
                command: ["sleep", "300"]
                user: "1000:1000"
                env_file: svc.env
                environment:
                  MODE: ${MODE}
                  DIRECT: "yes"
                labels:
                  surface: full
                dns: [8.8.8.8]
                cap_add: [CAP_NET_RAW]
                tmpfs: [/scratch]
                shm_size: 16M
                read_only: true
                init: true
                ports:
                  - target: 8080
                    published: \(hostPort)
                healthcheck:
                  test: ["CMD", "true"]
                  interval: 1s
                  timeout: 2s
                  retries: 3
                  start_period: 0s
                stop_grace_period: 30s
                networks: [\(harness.namespace)-front]
              worker:
                image: alpine:3.20
                container_name: \(harness.namespace)-worker
                command: ["sleep", "300"]
                depends_on:
                  api:
                    condition: service_healthy
            volumes:
              \(harness.namespace)-data:
            networks:
              \(harness.namespace)-front:
            """.write(to: composeURL, atomically: true, encoding: .utf8)

            let spec = try await harness.compose.parse(url: composeURL)
            let api = spec.services.first { $0.name == "api" }
            XCTAssertEqual(api?.user, "1000:1000")
            XCTAssertEqual(api?.dns, ["8.8.8.8"])
            XCTAssertEqual(api?.capAdd, ["CAP_NET_RAW"])
            XCTAssertEqual(api?.tmpfs, ["/scratch"])
            XCTAssertEqual(api?.shmSize, "16M")
            XCTAssertTrue(api?.readOnly ?? false)
            XCTAssertTrue(api?.init_p ?? false)
            XCTAssertEqual(api?.healthcheckIntervalSeconds, 1)
            XCTAssertEqual(api?.stopGracePeriodSeconds, 30)
            XCTAssertEqual(api?.environment.filter { $0.hasPrefix("MODE=") }, ["MODE=full"], "interpolation from .env")
            XCTAssertEqual(
                api?.environment.filter { $0.hasPrefix("FROM_FILE=") }, ["FROM_FILE=envfile-value"], "env_file values")

            let plan = try harness.compose.plan(spec: spec)
            var progress: [String] = []
            for try await line in await harness.compose.up(plan: plan) {
                progress.append(line)
            }
            XCTAssertTrue(
                progress.contains("\(harness.namespace)-api is ready"),
                "readiness probe must pass: \(progress)")

            let containers = try await harness.containers.list()
            let apiContainer = containers.first { $0.id.hasPrefix("\(harness.namespace)-api") }
            XCTAssertNotNil(apiContainer)
            XCTAssertEqual(apiContainer?.labels["surface"], "full")
            XCTAssertEqual(apiContainer?.labels["com.skunkworq.micropod.stop-grace"], "30")
            XCTAssertEqual(apiContainer?.env.contains("DIRECT=yes"), true)
            XCTAssertEqual(apiContainer?.env.contains("MODE=full"), true, "interpolated env reaches the container")
            XCTAssertEqual(apiContainer?.env.contains("FROM_FILE=envfile-value"), true)

            let raw = try await harness.containers.inspect(apiContainer!.id)
            let compactData = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: raw))
            let json = String(data: compactData, encoding: .utf8) ?? ""
            XCTAssertTrue(json.contains("\"userString\":\"1000:1000\""), "compose user applied")
            XCTAssertTrue(json.contains("\"capAdd\":[\"CAP_NET_RAW\"]"), "compose cap_add applied")
            XCTAssertTrue(json.contains("\"readOnly\":true"), "compose read_only applied")
            XCTAssertTrue(json.contains("\"source\":\"tmpfs\""), "compose tmpfs applied")

            let volumes = try await harness.volumes.list()
            XCTAssertTrue(volumes.contains { $0.id == "\(harness.namespace)-data" })
            let networks = try await harness.networks.list()
            XCTAssertTrue(networks.contains { $0.id == "\(harness.namespace)-front" })

            try await harness.compose.down(composeName: harness.namespace)
            let after = try await harness.containers.list()
            XCTAssertFalse(
                after.contains { $0.labels["com.skunkworq.micropod.compose"] == harness.namespace },
                "full-surface compose stack must be fully torn down")
        }
    }

    private func withRealHarness(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: (RealRuntimeHarness) async throws -> Void
    ) async throws {
        let harness = try RealRuntimeHarness(file: file, line: line)
        do {
            try await body(harness)
        } catch {
            await harness.cleanup()
            throw error
        }
        await harness.cleanup()
    }
}

/// Binds the real runtime with an isolated namespace and guaranteed cleanup.
final class RealRuntimeHarness {
    let client: ContainerCLIClient
    let system: SystemService
    let containers: ContainerService
    let images: ImageService
    let volumes: VolumeService
    let networks: NetworkService
    let stats: StatsSampler
    let logs: LogStreamer
    let compose: ComposeService
    let namespace: String
    let stateDir: URL

    init(file: StaticString = #filePath, line: UInt = #line) throws {
        guard ProcessInfo.processInfo.environment["MICROPOD_REAL_E2E"] == "1" else {
            throw XCTSkip("set MICROPOD_REAL_E2E=1 to run real-runtime tests", file: file, line: line)
        }
        let client = ContainerCLIClient()
        guard client.isAvailable() else {
            throw XCTSkip("`container` CLI not available", file: file, line: line)
        }
        self.client = client
        self.system = SystemService(client: client)
        self.containers = ContainerService(client: client)
        self.images = ImageService(client: client)
        self.volumes = VolumeService(client: client)
        self.networks = NetworkService(client: client)
        self.stats = StatsSampler(client: client)
        self.logs = LogStreamer(client: client)
        self.compose = ComposeService(client: client)
        self.namespace = "micropod-e2e-\(UUID().uuidString.prefix(8).lowercased())"
        self.stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(self.namespace)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    func name(_ suffix: String) -> String { "\(namespace)-\(suffix)" }

    /// `container stats` is occasionally slow on the real runtime; retry
    /// briefly before giving up.
    func snapshotWithRetry(attempts: Int = 3) async throws -> Micropod_V1_StatsSnapshot {
        var lastError: Error?
        for _ in 0..<attempts {
            do {
                return try await stats.snapshot()
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw lastError ?? MicropodError.message("stats snapshot failed")
    }

    /// Runs a long-lived alpine container that emits one log line on boot.
    func runAlive(name: String, network: String? = nil) async throws -> String {
        var request = ContainerRunRequest(
            image: "alpine:3.20",
            name: self.name(name),
            arguments: ["sh", "-c", "echo log-line; sleep 600"])
        if let network { request.networks = [network] }
        return try await containers.run(request)
    }

    /// Deletes every container/volume/network/image created under this
    /// namespace. Scans by prefix + compose label so cleanup is robust even
    /// if a test fails mid-way. Never touches anything outside the namespace.
    func cleanup() async {
        if let entries = try? await containers.list() {
            for container in entries
            where container.id.hasPrefix(namespace)
                || container.labels["com.skunkworq.micropod.compose"] == namespace
            {
                _ = try? await containers.stop(container.id, timeout: 5)
                _ = try? await containers.delete(container.id, force: true)
            }
        }
        if let listedVolumes = try? await volumes.list() {
            for volume in listedVolumes where volume.id.hasPrefix(namespace) {
                _ = try? await volumes.delete(volume.id)
            }
        }
        if let listedNetworks = try? await networks.list() {
            for network in listedNetworks where network.id.hasPrefix(namespace) {
                _ = try? await networks.delete(network.id)
            }
        }
        if let listedImages = try? await images.list() {
            for image in listedImages {
                guard let name = image.names.first(where: { $0.hasPrefix(namespace) }) else { continue }
                // The CLI deletes by reference (name), not raw id digest.
                _ = try? await images.delete(name, force: true)
            }
        }
        try? FileManager.default.removeItem(at: stateDir)
    }
}

/// A currently-free loopback TCP port for published-port tests. There is an
/// unavoidable TOCTOU gap between the close and the compose bind, but it beats
/// a hardcoded port colliding with unrelated long-lived processes (a stray
/// listener on 18080 once took the whole suite down).
private func ephemeralTCPPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { throw POSIXError(.EIO) }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &len)
        }
    }
    guard named == 0 else { throw POSIXError(.EIO) }
    return UInt16(bigEndian: addr.sin_port)
}
