import MicropodCore
import XCTest

/// Coverage for the extended docker-compose surface: full run-flag mapping,
/// interpolation + .env, long-syntax ports/volumes, depends_on conditions.
final class ComposeSurfaceTests: XCTestCase {
    private func composeFixture(_ yaml: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-surface-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("docker-compose.yml")
        try! yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testRunRequestCarriesFullContainerSurface() async throws {
        try await withMockServices { mock in
            let file = composeFixture(
                """
                services:
                  app:
                    image: nginx:1.27
                    user: "1000:1000"
                    entrypoint: ["/bin/sh", "-c"]
                    command: ["sleep 300"]
                    labels:
                      team: backend
                      tier: prod
                    dns:
                      - 8.8.8.8
                      - 1.1.1.1
                    dns_search: [example.com]
                    cap_add: [CAP_NET_RAW]
                    cap_drop: [CAP_SYS_ADMIN]
                    ulimits:
                      nofile:
                        soft: 1024
                        hard: 2048
                    tmpfs: [/run]
                    shm_size: 64M
                    read_only: true
                    init: true
                    tty: true
                    stdin_open: true
                    deploy:
                      resources:
                        limits:
                          cpus: "0.25"
                          memory: 128M
                """)
            let spec = try await mock.compose.parse(url: file)
            let plan = try mock.compose.plan(spec: spec)
            let runStep = plan.steps.first {
                if case .run = $0 { return true }
                return false
            }
            guard case .run(let request)? = runStep else {
                return XCTFail("expected a run step")
            }
            XCTAssertEqual(request.user, "1000:1000")
            XCTAssertEqual(request.entrypoint, "/bin/sh -c")
            XCTAssertEqual(request.arguments, ["sleep 300"])
            XCTAssertEqual(request.dns, ["8.8.8.8", "1.1.1.1"])
            XCTAssertEqual(request.dnsSearch, ["example.com"])
            XCTAssertEqual(request.capAdd, ["CAP_NET_RAW"])
            XCTAssertEqual(request.capDrop, ["CAP_SYS_ADMIN"])
            XCTAssertEqual(request.ulimits, ["nofile=1024:2048"])
            XCTAssertEqual(request.tmpfs, ["/run"])
            XCTAssertEqual(request.shmSize, "64M")
            XCTAssertTrue(request.readOnly)
            XCTAssertTrue(request.useInit)
            XCTAssertTrue(request.tty)
            XCTAssertTrue(request.interactive)
            XCTAssertEqual(request.cpus, 0.25)
            XCTAssertEqual(request.memory, "128M")
            XCTAssertTrue(request.labels.contains { $0.key == "team" && $0.value == "backend" })
            XCTAssertTrue(request.labels.contains { $0.key == "com.skunkworq.micropod.compose" })

            // And the mock CLI records them on the container.
            for try await _ in await mock.compose.up(plan: plan) {}
            let containers = try await mock.containers.list()
            XCTAssertEqual(containers.count, 1)
            let raw = try await mock.containers.inspect(containers[0].id)
            let json = String(data: raw, encoding: .utf8) ?? ""
            XCTAssertTrue(json.contains("\"user\":\"1000:1000\""))
            XCTAssertTrue(json.contains("\"shmSize\":\"64M\""))
            XCTAssertTrue(json.contains("\"capAdd\":[\"CAP_NET_RAW\"]"))
            XCTAssertTrue(json.contains("\"capDrop\":[\"CAP_SYS_ADMIN\"]"))
            XCTAssertTrue(json.contains("\"ulimits\":[\"nofile=1024:2048\"]"))
            XCTAssertTrue(json.contains("\"tmpfs\":[\"/run\"]"))
            XCTAssertTrue(json.contains("\"dns\":[\"8.8.8.8\""))
        }
    }

    func testEnvironmentInterpolationAndEnvFile() async throws {
        try await withMockServices { mock in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("compose-env-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            try "MODE=staging\nBACKEND_URL=http://backend\nexpanded_value=ok\n".write(
                to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
            try "FROM_FILE=file-value\nSHARED=file\n".write(
                to: dir.appendingPathComponent("service.env"), atomically: true, encoding: .utf8)

            let file = dir.appendingPathComponent("docker-compose.yml")
            try """
            services:
              app:
                image: nginx:1.27
                env_file: service.env
                environment:
                  MODE: ${MODE}
                  URL: ${BACKEND_URL:-http://localhost}
                  TOKEN: ${MISSING_TOKEN:-default-token}
                  COUNT: ${MISSING_COUNT-5}
                  LITERAL: $100
                  SHARED: compose-wins
                  INTERP: ${expanded_value}
            """.write(to: file, atomically: true, encoding: .utf8)

            let spec = try await mock.compose.parse(url: file)
            let app = spec.services.first { $0.name == "app" }
            XCTAssertNotNil(app)
            let env = app?.environment ?? []
            XCTAssertTrue(env.contains("MODE=staging"), "interpolates from .env: \(env)")
            XCTAssertTrue(env.contains("URL=http://backend"), ":- fallback prefers .env value")
            XCTAssertTrue(env.contains("TOKEN=default-token"), ":- fallback for missing var")
            XCTAssertTrue(env.contains("COUNT=5"), "- fallback for missing var")
            XCTAssertTrue(env.contains("LITERAL=$100"), "dollar numbers are literal")
            XCTAssertTrue(env.contains("FROM_FILE=file-value"), "env_file values load")
            XCTAssertTrue(env.contains("SHARED=compose-wins"), "environment overrides env_file")
            XCTAssertTrue(env.contains("INTERP=ok"))
        }
    }

    func testPortLongSyntaxAndHostIP() async throws {
        try await withMockServices { mock in
            let file = composeFixture(
                """
                services:
                  web:
                    image: nginx:1.27
                    ports:
                      - target: 80
                        published: 8080
                        protocol: tcp
                        host_ip: "127.0.0.1"
                      - target: 443
                        published: 8443
                        protocol: udp
                  plain:
                    image: alpine:3.20
                    ports:
                      - "127.0.0.1:9090:80"
                """)
            let spec = try await mock.compose.parse(url: file)
            let plan = try mock.compose.plan(spec: spec)
            let runSteps = plan.steps.compactMap { step -> ContainerRunRequest? in
                if case .run(let request) = step { return request }
                return nil
            }
            let web = runSteps.first { $0.name == "web" }
            XCTAssertEqual(web?.publishedPorts.count, 2)
            XCTAssertEqual(web?.publishedPorts[0].hostPort, 8080)
            XCTAssertEqual(web?.publishedPorts[0].containerPort, 80)
            XCTAssertEqual(web?.publishedPorts[0].hostIP, "127.0.0.1")
            XCTAssertEqual(web?.publishedPorts[0].transportProtocol, "tcp")
            XCTAssertEqual(web?.publishedPorts[1].transportProtocol, "udp")

            let plain = runSteps.first { $0.name == "plain" }
            XCTAssertEqual(plain?.publishedPorts[0].hostPort, 9090)
            XCTAssertEqual(plain?.publishedPorts[0].hostIP, "127.0.0.1")
        }
    }

    func testVolumeLongSyntaxBindTmpfsAndReadOnly() async throws {
        try await withMockServices { mock in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("compose-volumes-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "data".write(to: dir.appendingPathComponent("host-data.txt"), atomically: true, encoding: .utf8)
            let file = dir.appendingPathComponent("docker-compose.yml")
            try """
            services:
              app:
                image: nginx:1.27
                volumes:
                  - type: volume
                    source: data
                    target: /var/lib/data
                    read_only: true
                  - type: bind
                    source: ./host-data.txt
                    target: /etc/config
                  - type: tmpfs
                    target: /scratch
                  - ./relative-bind:/mnt
            volumes:
              data:
            """.write(to: file, atomically: true, encoding: .utf8)

            let spec = try await mock.compose.parse(url: file)
            let app = spec.services.first { $0.name == "app" }
            XCTAssertEqual(app?.volumes.count, 3)
            XCTAssertTrue(app?.volumes.contains("data:/var/lib/data:ro") ?? false)
            let bind = app?.volumes.first { $0.hasSuffix("/host-data.txt:/etc/config") }
            XCTAssertNotNil(bind, "bind source resolves relative to compose dir: \(app?.volumes ?? [])")
            XCTAssertTrue(app?.tmpfs.contains("/scratch") ?? false)
            XCTAssertTrue(app?.volumes.contains("./relative-bind:/mnt") ?? false)
        }
    }

    func testVolumeAndNetworkOptionsFlowThrough() async throws {
        try await withMockServices { mock in
            let file = composeFixture(
                """
                services:
                  app:
                    image: nginx:1.27
                volumes:
                  data:
                    driver: local
                    driver_opts:
                      size: 100M
                    labels:
                      purpose: cache
                networks:
                  front:
                    driver_opts:
                      mtu: 9000
                    labels:
                      team: web
                    ipam:
                      config:
                        - subnet: 10.9.0.0/24
                          subnet_v6: fd00:9::/64
                """)
            let spec = try await mock.compose.parse(url: file)
            let dataVolume = spec.volumes["data"]
            XCTAssertEqual(dataVolume?.driver, "local")
            XCTAssertEqual(dataVolume?.driverOpts, ["size=100M"])
            XCTAssertEqual(dataVolume?.labels, ["purpose=cache"])
            let front = spec.networks["front"]
            XCTAssertEqual(front?.driverOpts, ["mtu=9000"])
            XCTAssertEqual(front?.labels, ["team=web"])
            XCTAssertEqual(front?.subnet, "10.9.0.0/24")
            XCTAssertEqual(front?.subnetV6, "fd00:9::/64")

            // And they flow through to the mock's state.
            let plan = try mock.compose.plan(spec: spec)
            for try await _ in await mock.compose.up(plan: plan) {}

            let volumes = try await mock.volumes.list()
            let created = volumes.first { $0.id == "data" }
            XCTAssertEqual(created?.labels["purpose"], "cache")
            XCTAssertEqual(
                created?.sizeBytes, 104_857_600, "driver_opts size maps through --opt? no — volume create --size")

            let networks = try await mock.networks.list()
            let createdNet = networks.first { $0.id == "front" }
            XCTAssertEqual(createdNet?.ipv4Subnet, "10.9.0.0/24")
            XCTAssertEqual(createdNet?.ipv6Subnet, "fd00:9::/64")
            XCTAssertEqual(createdNet?.labels["team"], "web")
        }
    }

    func testContainersAttachToComposeNetworks() async throws {
        try await withMockServices { mock in
            let file = composeFixture(
                """
                services:
                  web:
                    image: nginx:1.27
                    networks: [front, back]
                networks:
                  front:
                  back:
                """)
            let spec = try await mock.compose.parse(url: file)
            let plan = try mock.compose.plan(spec: spec)
            XCTAssertEqual(plan.createdNetworks, ["back", "front"])

            for try await _ in await mock.compose.up(plan: plan) {}
            let containers = try await mock.containers.list()
            XCTAssertEqual(containers[0].networks.sorted(), ["back", "front"])

            let networks = try await mock.networks.list()
            XCTAssertEqual(networks.map(\.id).sorted(), ["back", "front"])
        }
    }

    func testGracePeriodUsedByDown() async throws {
        try await withMockServices { mock in
            let file = composeFixture(
                """
                services:
                  app:
                    image: nginx:1.27
                    stop_grace_period: 45s
                """)
            let spec = try await mock.compose.parse(url: file)
            let plan = try mock.compose.plan(spec: spec)
            for try await _ in await mock.compose.up(plan: plan) {}

            let containers = try await mock.containers.list()
            XCTAssertEqual(containers.count, 1)
            XCTAssertEqual(
                containers[0].labels["com.skunkworq.micropod.stop-grace"], "45",
                "grace period must be stamped for down to honor")

            try await mock.compose.down(composeName: "docker-compose")
            let remaining = try await mock.containers.list()
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testProfilesGateServices() async throws {
        try await withMockServices { mock in
            let file = composeFixture(
                """
                services:
                  core:
                    image: alpine:3.20
                  debug:
                    image: alpine:3.20
                    profiles: [debug]
                  staging:
                    image: alpine:3.20
                    profiles: [staging, debug]
                """)
            let spec = try await mock.compose.parse(url: file)
            let debug = spec.services.first { $0.name == "debug" }
            XCTAssertEqual(debug?.profiles, ["debug"])

            // Default plan: only unprofiled services.
            let defaultPlan = try mock.compose.plan(spec: spec)
            let defaultRuns = defaultPlan.steps.compactMap { step -> String? in
                if case .run(let request) = step { return request.name }
                return nil
            }
            XCTAssertEqual(defaultRuns, ["core"], "profiled services must not run by default")

            // With the debug profile enabled: core + debug + staging (staging
            // shares the debug profile).
            let debugPlan = try mock.compose.plan(spec: spec, enabledProfiles: ["debug"])
            let debugRuns = debugPlan.steps.compactMap { step -> String? in
                if case .run(let request) = step { return request.name }
                return nil
            }
            XCTAssertEqual(debugRuns, ["core", "debug", "staging"], "intersecting profiles enable services")

            // The debug profile plan actually starts the containers.
            for try await _ in await mock.compose.up(plan: debugPlan) {}
            let containers = try await mock.containers.list()
            XCTAssertEqual(containers.map(\.id).count, 3)
        }
    }

    func testPullOnlyWhenImageMissing() async throws {
        try await withMockServices { mock in
            // Pre-pull so the image is already local.
            for try await _ in mock.images.pull("alpine:3.20", platform: nil) {}

            let file = composeFixture(
                """
                services:
                  app:
                    image: alpine:3.20
                """)
            let spec = try await mock.compose.parse(url: file)
            let plan = try mock.compose.plan(spec: spec)

            var progress: [String] = []
            for try await line in await mock.compose.up(plan: plan) {
                progress.append(line)
            }
            XCTAssertTrue(
                progress.contains("Image alpine:3.20 already present"),
                "docker's default pull_policy skips local images: \(progress)")
            XCTAssertFalse(progress.contains { $0.hasPrefix("Pulling") }, "must not pull when present")

            // pull_policy: always forces the pull.
            let forced = composeFixture(
                """
                services:
                  app:
                    image: alpine:3.20
                    pull_policy: always
                """)
            let forcedSpec = try await mock.compose.parse(url: forced)
            let forcedPlan = try mock.compose.plan(spec: forcedSpec)
            var forcedProgress: [String] = []
            for try await line in await mock.compose.up(plan: forcedPlan) {
                forcedProgress.append(line)
            }
            XCTAssertTrue(
                forcedProgress.contains { $0.hasPrefix("Pulling alpine:3.20") },
                "pull_policy: always must pull: \(forcedProgress)")
        }
    }

    func testRestartStopsThenStarts() async throws {
        try await withMockServices { mock in
            let id = try await mock.runContainer(name: "web")
            try await mock.containers.restart(id)
            let containers = try await mock.containers.list()
            XCTAssertEqual(containers.count, 1)
            XCTAssertEqual(containers[0].state, "running", "restart must leave the container running")
            XCTAssertFalse(containers[0].ipv4Address.isEmpty, "restarted container gets a fresh IP")
        }
    }

    func testBuildTargetAndPlatformInPlan() async throws {
        try await withMockServices { mock in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("compose-build-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "FROM scratch\n".write(to: dir.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
            let file = dir.appendingPathComponent("docker-compose.yml")
            try """
            services:
              app:
                build:
                  context: .
                  target: runtime
                  platform: linux/arm64
                  args:
                    VERSION: "3"
            """.write(to: file, atomically: true, encoding: .utf8)

            let spec = try await mock.compose.parse(url: file)
            let app = spec.services.first { $0.name == "app" }
            XCTAssertEqual(app?.buildTarget, "runtime")
            XCTAssertEqual(app?.buildPlatform, "linux/arm64")
            XCTAssertEqual(app?.buildArgs, ["VERSION=3"])

            let plan = try mock.compose.plan(spec: spec)
            let buildStep = plan.steps.first {
                if case .build = $0 { return true }
                return false
            }
            guard case .build(let request, _)? = buildStep else {
                return XCTFail("expected a build step")
            }
            XCTAssertEqual(request.target, "runtime")
            XCTAssertEqual(request.platform, "linux/arm64")
            XCTAssertEqual(request.buildArgs, ["VERSION=3"])
        }
    }
}
