import XCTest

@testable import MicropodCore

final class ComposeServiceTests: XCTestCase {
    private func makeService() -> ComposeService {
        ComposeService(client: ContainerCLIClient())
    }

    func testParseSimpleComposeFile() async throws {
        let fixture = composeFixture(
            """
            services:
              web:
                image: nginx:1.27
                ports:
                  - "8080:80"
                environment:
                  - FOO=bar
              db:
                image: postgres:16
                environment:
                  POSTGRES_PASSWORD: secret
                volumes:
                  - pgdata:/var/lib/postgresql/data
                depends_on:
                  - web
            volumes:
              pgdata:
            """)
        let spec = try await makeService().parse(url: fixture)
        XCTAssertEqual(spec.services.count, 2)
        let web = spec.services.first { $0.name == "web" }
        XCTAssertEqual(web?.image, "nginx:1.27")
        XCTAssertEqual(web?.ports.count, 1)
        XCTAssertEqual(web?.ports[0].hostPort, 8080)
        XCTAssertEqual(web?.ports[0].containerPort, 80)
        XCTAssertEqual(web?.environment, ["FOO=bar"])

        let db = spec.services.first { $0.name == "db" }
        XCTAssertEqual(db?.environment, ["POSTGRES_PASSWORD=secret"])
        XCTAssertEqual(db?.dependsOn, ["web"])
        XCTAssertEqual(spec.volumes["pgdata"]?.name, "pgdata")
    }

    func testPlanOrdersDependencies() async throws {
        let fixture = composeFixture(
            """
            services:
              app:
                image: myapp:latest
                depends_on:
                  db:
                    condition: service_healthy
                  cache:
                    condition: service_started
              cache:
                image: redis:7
              db:
                image: postgres:16
                healthcheck:
                  test: ["CMD", "pg_isready", "-U", "postgres"]
            """)
        let spec = try await makeService().parse(url: fixture)
        let plan = try makeService().plan(spec: spec)

        let runIndexes = plan.steps.enumerated().compactMap { index, step -> (Int, String)? in
            if case .run(let request) = step {
                return (index, request.name ?? "")
            }
            return nil
        }
        let order = runIndexes.map(\.1)
        XCTAssertEqual(
            order, ["cache", "db", "app"],
            "dependent services must start after their dependencies (dict-form depends_on sorts keys)")

        let readinessIndexes = plan.steps.enumerated().compactMap { index, step -> (Int, String)? in
            if case .readiness(let service) = step { return (index, service.containerName) }
            return nil
        }
        XCTAssertEqual(readinessIndexes.map(\.1), ["db"], "readiness only for service_healthy dependencies")
    }

    func testPlanSkipsReadinessWithoutHealthyCondition() async throws {
        let fixture = composeFixture(
            """
            services:
              app:
                image: myapp:latest
                depends_on: [db]
              db:
                image: postgres:16
                healthcheck:
                  test: ["CMD", "pg_isready"]
            """)
        let spec = try await makeService().parse(url: fixture)
        let plan = try makeService().plan(spec: spec)
        let readinessSteps = plan.steps.filter {
            if case .readiness = $0 { return true }
            return false
        }
        XCTAssertTrue(readinessSteps.isEmpty, "plain depends_on must not probe health")
    }

    func testPlanBuildsFromContext() async throws {
        let fixture = composeFixture(
            """
            services:
              app:
                build:
                  context: .
                  dockerfile: Dockerfile.dev
            """)
        let spec = try await makeService().parse(url: fixture)
        let plan = try makeService().plan(spec: spec)
        let buildSteps = plan.steps.filter {
            if case .build = $0 { return true }
            return false
        }
        XCTAssertEqual(buildSteps.count, 1)
        if case .build(let request, let tag) = buildSteps[0] {
            XCTAssertTrue(
                request.contextDirectory.contains("compose-fixtures-"),
                "resolved context dir was \(request.contextDirectory)")
            XCTAssertEqual(request.dockerfile, "Dockerfile.dev")
            XCTAssertEqual(tag, "docker-compose-app:latest")
        } else {
            XCTFail("expected build step")
        }
    }

    func testPlanDetectsCycle() async throws {
        let fixture = composeFixture(
            """
            services:
              a:
                image: x
                depends_on: [b]
              b:
                image: y
                depends_on: [a]
            """)
        let spec = try await makeService().parse(url: fixture)
        XCTAssertThrowsError(try makeService().plan(spec: spec)) { error in
            XCTAssertTrue(error.localizedDescription.contains("cycle"))
        }
    }

    func testRunRequestFromCompose() async throws {
        let fixture = composeFixture(
            """
            services:
              web:
                image: nginx
                ports:
                  - "127.0.0.1:8080:80/udp"
                cpus: 0.5
                mem_limit: 256M
            """)
        let spec = try await makeService().parse(url: fixture)
        let plan = try makeService().plan(spec: spec)
        let runStep = plan.steps.first {
            if case .run = $0 { return true }
            return false
        }
        guard case .run(let request)? = runStep else {
            return XCTFail("expected run step")
        }
        XCTAssertEqual(request.cpus, 0.5)
        XCTAssertEqual(request.memory, "256M")
        XCTAssertEqual(request.publishedPorts.count, 1)
        XCTAssertEqual(request.publishedPorts[0].hostPort, 8080)
        XCTAssertEqual(request.publishedPorts[0].transportProtocol, "udp")
        XCTAssertTrue(request.labels.contains { $0.key == "com.skunkworq.micropod.compose" })
    }

    func testExternalNameOverridesAndHealthcheckDisable() async throws {
        let fixture = composeFixture(
            """
            services:
              app:
                image: nginx:1.27
                networks: [shared]
                volumes:
                  - extdata:/data
                healthcheck:
                  disable: true
            volumes:
              extdata:
                external:
                  name: shared-data-store
            networks:
              shared:
                external:
                  name: shared-net-42
            """)
        let spec = try await makeService().parse(url: fixture)

        let extData = spec.volumes["extdata"]
        XCTAssertTrue(extData?.external == true)
        XCTAssertEqual(extData?.externalName, "shared-data-store")

        let shared = spec.networks["shared"]
        XCTAssertTrue(shared?.external == true)
        XCTAssertEqual(shared?.externalName, "shared-net-42")

        let app = spec.services.first { $0.name == "app" }
        XCTAssertTrue(app?.healthcheckCommand.isEmpty == true, "disabled healthcheck must clear the probe")
        XCTAssertEqual(app?.healthcheckCommand, "")

        // External resources are not created by the plan.
        let plan = try makeService().plan(spec: spec)
        XCTAssertTrue(plan.createdNetworks.isEmpty)
        XCTAssertTrue(plan.createdVolumes.isEmpty)

        // The run request resolves external names and attaches networks.
        let runStep = plan.steps.first {
            if case .run = $0 { return true }
            return false
        }
        guard case .run(let request)? = runStep else {
            return XCTFail("expected run step")
        }
        XCTAssertEqual(request.networks, ["shared-net-42"])
        XCTAssertTrue(request.volumes.contains("extdata:/data"), "external volume mounts stay keyed")
    }

    func testBuildNoCacheParsed() async throws {
        let fixture = composeFixture(
            """
            services:
              app:
                build:
                  context: .
                  no_cache: true
            """)
        let spec = try await makeService().parse(url: fixture)
        XCTAssertTrue(spec.services[0].buildNoCache)
    }

    func testStopGracePeriodStampedOnRun() async throws {
        let fixture = composeFixture(
            """
            services:
              app:
                image: nginx:1.27
                stop_grace_period: 45s
            """)
        let spec = try await makeService().parse(url: fixture)
        XCTAssertEqual(spec.services[0].stopGracePeriodSeconds, 45)
        let plan = try makeService().plan(spec: spec)
        let runStep = plan.steps.first {
            if case .run = $0 { return true }
            return false
        }
        guard case .run(let request)? = runStep else {
            return XCTFail("expected run step")
        }
        XCTAssertTrue(
            request.labels.contains { $0.key == "com.skunkworq.micropod.stop-grace" && $0.value == "45" })
    }

    func testStartUpCancellationTerminatesProducerAndStreamPromptly() async throws {
        var service = Micropod_V1_ComposeService()
        service.containerName = "slow-service"
        service.healthcheckCommand = "true"
        service.healthcheckStartPeriodSeconds = 30
        let plan = ComposePlan(steps: [.readiness(service)], composeName: "slow-stack")
        let execution = makeService().startUp(plan: plan)
        var iterator = execution.stream.makeAsyncIterator()
        let firstEvent = try await iterator.next()
        XCTAssertEqual(firstEvent, "Waiting for slow-service to be ready…")

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        execution.task.cancel()
        await execution.task.value

        XCTAssertLessThan(cancelledAt.duration(to: clock.now), .seconds(1))
        do {
            _ = try await iterator.next()
            XCTFail("Expected the stream to finish with cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testStartUpCancellationDuringPullDoesNotReportSuccess() async throws {
        let executable = try executableFixture(
            """
            #!/bin/sh
            sleep 5
            """)
        defer { try? FileManager.default.removeItem(at: executable) }
        let service = ComposeService(client: ContainerCLIClient(executableURL: executable))
        let plan = ComposePlan(
            steps: [.pull(image: "slow:latest", force: true)],
            composeName: "slow-pull")
        let execution = service.startUp(plan: plan)
        var iterator = execution.stream.makeAsyncIterator()
        let firstEvent = try await iterator.next()
        XCTAssertEqual(firstEvent, "Pulling slow:latest…")

        execution.task.cancel()
        await execution.task.value

        do {
            let nextEvent = try await iterator.next()
            XCTFail("Expected cancellation, got \(nextEvent ?? "stream completion")")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    private func composeFixture(_ yaml: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-fixtures-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("docker-compose.yml")
        try! yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func executableFixture(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-executable-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

// MARK: - 3.3 YAML round-trip

extension ComposeServiceTests {
    /// Serialize a parsed spec to YAML, re-parse it, and verify the round
    /// trip preserves the services/networks/volumes the parser understands.
    func testComposeYAMLRoundTrip() async throws {
        let fixture = composeFixture(
            """
            name: stack
            services:
              web:
                image: nginx:1.27
                ports:
                  - "8080:80"
                environment:
                  - FOO=bar
                networks:
                  - front
                healthcheck:
                  test: ["CMD", "true"]
                  interval: 2s
                  retries: 5
              db:
                image: postgres:16
                depends_on:
                  web:
                    condition: service_healthy
                volumes:
                  - pgdata:/var/lib/postgresql/data
            volumes:
              pgdata:
            networks:
              front:
            """)
        let spec = try await makeService().parse(url: fixture)
        let yaml = composeYAML(from: spec)
        XCTAssertTrue(yaml.contains("name: stack"), "missing name: \(yaml)")
        XCTAssertTrue(yaml.contains("image: nginx:1.27"))
        XCTAssertTrue(yaml.contains("8080:80"))
        XCTAssertTrue(yaml.contains("service_healthy"))

        // Re-parse the emitted YAML and compare the meaningful surface.
        let reparseURL = fixture.deletingLastPathComponent().appendingPathComponent("roundtrip.yml")
        try yaml.write(to: reparseURL, atomically: true, encoding: .utf8)
        let reparsed = try await makeService().parse(url: reparseURL)
        XCTAssertEqual(reparsed.name, spec.name)
        XCTAssertEqual(reparsed.services.count, spec.services.count)
        let web = reparsed.services.first { $0.name == "web" }
        XCTAssertEqual(web?.image, "nginx:1.27")
        XCTAssertEqual(web?.ports.map { "\($0.hostPort):\($0.containerPort)" }, ["8080:80"])
        XCTAssertEqual(web?.networks, ["front"])
        let db = reparsed.services.first { $0.name == "db" }
        XCTAssertEqual(db?.dependsOn, ["web"])
        XCTAssertEqual(db?.dependsOnConditions["web"], "service_healthy")
    }
}
