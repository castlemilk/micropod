import MicropodCore
import XCTest

final class ComposeIntegrationTests: XCTestCase {
    private func composeFixture(_ yaml: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-e2e-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("docker-compose.yml")
        try! yaml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testComposeUpCreatesContainersVolumesAndNetworks() async throws {
        try await withMockServices { mock in
            let file = composeFixture(
                """
                name: stack
                services:
                  web:
                    image: nginx:1.27
                    ports:
                      - "8080:80"
                    networks:
                      - front
                    healthcheck:
                      test: ["CMD", "true"]
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
            let spec = try await mock.compose.parse(url: file)
            XCTAssertEqual(spec.name, "stack")
            let plan = try mock.compose.plan(spec: spec)
            XCTAssertEqual(plan.createdNetworks, ["front"])
            XCTAssertEqual(plan.createdVolumes, ["pgdata"])

            var progress: [String] = []
            for try await line in await mock.compose.up(plan: plan) {
                progress.append(line)
            }

            XCTAssertTrue(progress.contains("Network front created"))
            XCTAssertTrue(progress.contains("Volume pgdata created"))
            XCTAssertTrue(progress.contains("Started web"))
            XCTAssertTrue(progress.contains("Started db"))
            XCTAssertTrue(
                progress.contains("web is ready"),
                "service_healthy dependency must probe web's healthcheck: \(progress)")

            let containers = try await mock.containers.list()
            XCTAssertEqual(containers.count, 2)
            let labels = Set(containers.flatMap { $0.labels.keys })
            XCTAssertTrue(labels.contains("com.skunkworq.micropod.compose"))

            let volumes = try await mock.volumes.list()
            XCTAssertTrue(volumes.contains { $0.id == "pgdata" })

            let networks = try await mock.networks.list()
            XCTAssertTrue(networks.contains { $0.id == "front" })
        }
    }

    /// Feeds the real `up` stream through the ComposeView stepper state
    /// machine (`ComposeRunState`) — the exact path the UI uses — and asserts
    /// every step lands on success and the pipeline closes out.
    func testComposeStepperTracksRealStreamToSuccess() async throws {
        try await withMockServices { mock in
            let file = composeFixture(
                """
                name: stack
                services:
                  web:
                    image: nginx:1.27
                    networks:
                      - front
                    healthcheck:
                      test: ["CMD", "true"]
                networks:
                  front:
                """)
            let spec = try await mock.compose.parse(url: file)
            let plan = try mock.compose.plan(spec: spec)

            var state = ComposeRunState(
                steps: plan.steps.enumerated().map {
                    ComposeRunState.StepState(step: $1, index: $0)
                })
            XCTAssertEqual(state.steps.count, plan.steps.count)

            for try await line in await mock.compose.up(plan: plan) {
                state.consume(line)
            }
            state.markAllPendingSuccess()

            XCTAssertEqual(state.status, .success, "steps: \(state.steps.map(\.status))")
            XCTAssertEqual(state.cursor, state.steps.count)
            XCTAssertEqual(state.rawLog.count, state.steps.reduce(0) { $0 + $1.detail.count })
            XCTAssertTrue(state.steps.contains { $0.title == "Network front" })
            XCTAssertTrue(state.steps.allSatisfy { $0.status == .success })
        }
    }

    func testComposeDownTearsDownEverything() async throws {
        try await withMockServices { mock in
            let file = composeFixture(
                """
                name: stack
                services:
                  web:
                    image: nginx:1.27
                  db:
                    image: postgres:16
                    depends_on: [web]
                    volumes:
                      - pgdata:/var/lib/postgresql/data
                volumes:
                  pgdata:
                networks:
                  front:
                """)
            let spec = try await mock.compose.parse(url: file)
            let plan = try mock.compose.plan(spec: spec)
            for try await _ in await mock.compose.up(plan: plan) {}

            let containers = try await mock.containers.list()
            XCTAssertEqual(containers.count, 2)

            try await mock.compose.down(composeName: "stack")

            let remaining = try await mock.containers.list()
            let volumes = try await mock.volumes.list()
            let networks = try await mock.networks.list()
            XCTAssertTrue(remaining.isEmpty, "containers removed on down")
            XCTAssertTrue(volumes.isEmpty, "volumes pruned on down")
            XCTAssertTrue(networks.isEmpty, "networks pruned on down")
        }
    }

    func testComposeBuildsServiceFromContext() async throws {
        try await withMockServices { mock in
            let dir = composeFixture(
                """
                name: builder
                services:
                  app:
                    build:
                      context: .
                      dockerfile: Dockerfile.dev
                """)
            // The mock requires a real build context directory.
            let context = dir.deletingLastPathComponent()
            try "FROM scratch".write(
                to: context.appendingPathComponent("Dockerfile.dev"), atomically: true, encoding: .utf8)

            let spec = try await mock.compose.parse(url: dir)
            let plan = try mock.compose.plan(spec: spec)
            let buildSteps = plan.steps.filter {
                if case .build = $0 { return true }
                return false
            }
            XCTAssertEqual(buildSteps.count, 1)

            var progress: [String] = []
            for try await line in await mock.compose.up(plan: plan) {
                progress.append(line)
            }
            XCTAssertTrue(progress.contains { $0.hasPrefix("Built ") })

            let images = try await mock.images.list()
            XCTAssertTrue(images.contains { $0.names.contains("builder-app:latest") })
        }
    }

    func testComposeDownOnlyTargetsLabelledContainers() async throws {
        try await withMockServices { mock in
            let unrelated = try await mock.runContainer(name: "unrelated")

            let file = composeFixture(
                """
                name: stack
                services:
                  web:
                    image: nginx:1.27
                """)
            let spec = try await mock.compose.parse(url: file)
            let plan = try mock.compose.plan(spec: spec)
            for try await _ in await mock.compose.up(plan: plan) {}

            try await mock.compose.down(composeName: "stack")

            let remaining = try await mock.containers.list()
            XCTAssertEqual(remaining.map(\.id), [unrelated])
        }
    }
}
