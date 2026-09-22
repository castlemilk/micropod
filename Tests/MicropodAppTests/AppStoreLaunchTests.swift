import MicropodCore
import XCTest

@testable import MicropodApp

@MainActor
final class AppStoreLaunchTests: XCTestCase {
    func testSuccessfulLaunchIsTrackedRefreshedAndSelected() async throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = makeRunningStore(client: fixture.client)
        store.lastRefreshError = "stale error"

        let operationID = store.startRunContainer(
            ContainerRunRequest(image: "alpine:latest", name: "agent-one"))

        try await waitUntil { store.operationRegistry.operation(operationID)?.status != .running }

        XCTAssertEqual(store.operationRegistry.operation(operationID)?.status, .succeeded)
        XCTAssertEqual(store.containers.map(\.id), ["mpc-0001"])
        XCTAssertEqual(store.selectedContainerID, "mpc-0001")
        XCTAssertNil(store.lastRefreshError)
        XCTAssertTrue(
            store.activity.contains {
                $0.category == "containers" && $0.level == .success && $0.message.contains("agent-one")
            })
    }

    func testAttachedLaunchSelectionIgnoresProcessOutput() {
        let request = ContainerRunRequest(
            image: "alpine:latest",
            name: "attached-job",
            detach: false)
        let existing = container(id: "existing", labels: [:])
        let attached = container(id: "attached-job", labels: [:])

        XCTAssertEqual(
            launchedContainerID(
                runOutput: "hello from the workload",
                request: request,
                previousIDs: [existing.id],
                refreshedContainers: [existing, attached]),
            "attached-job")
    }

    func testAttachedLaunchWithoutNameSelectsTheOnlyNewContainer() {
        let request = ContainerRunRequest(image: "alpine:latest", detach: false)
        let existing = container(id: "existing", labels: [:])
        var attached = container(id: "generated-id", labels: [:])
        attached.image = "alpine:latest"

        XCTAssertEqual(
            launchedContainerID(
                runOutput: "hello from the workload",
                request: request,
                previousIDs: [existing.id],
                refreshedContainers: [existing, attached]),
            "generated-id")
    }

    func testFailedLaunchIsTrackedAndSurfaced() async throws {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())

        let operationID = store.startRunContainer(
            ContainerRunRequest(image: "missing.example/fail:latest", name: "broken"))

        try await waitUntil { store.operationRegistry.operation(operationID)?.status != .running }

        guard case .failed(let message) = store.operationRegistry.operation(operationID)?.status else {
            return XCTFail("Expected a failed operation")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(store.lastRefreshError, message)
        XCTAssertTrue(
            store.activity.contains {
                $0.category == "containers" && $0.level == .error && $0.message.contains("broken")
            })
    }

    func testCancellationDuringRefreshStillCommitsSuccessfulLaunch() async throws {
        let fixture = try AppTestCLI.makeMock(listDelaySeconds: 1)
        defer { AppTestCLI.cleanUp(fixture) }
        let store = makeRunningStore(client: fixture.client)
        let operationID = store.startRunContainer(
            ContainerRunRequest(image: "alpine:latest", name: "committed"))

        try await waitUntil {
            let trace = (try? String(contentsOf: fixture.traceURL, encoding: .utf8)) ?? ""
            return trace.contains("completed run ") && trace.contains("\nlist --all")
        }
        store.cancelOperation(operationID)
        try await waitUntil(timeout: .seconds(5)) {
            store.operationRegistry.operation(operationID)?.status != .running
        }

        XCTAssertEqual(store.operationRegistry.operation(operationID)?.status, .succeeded)
        XCTAssertEqual(store.selectedContainerID, "mpc-0001")
        XCTAssertEqual(store.containers.map(\.id), ["mpc-0001"])
        XCTAssertTrue(
            store.activity.contains {
                $0.category == "containers" && $0.level == .success && $0.message.contains("committed")
            })
    }

    func testAgentWorkloadCountUsesOnlyExactMicropodAndCuttlefishLabels() {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        store.containers = [
            container(id: "micropod-agent", labels: ["com.micropod.agent": "true"]),
            container(id: "cuttlefish-agent", labels: ["com.cuttlefish.job": "job-42"]),
            container(id: "micropod-job-only", labels: ["com.micropod.job": "job-43"]),
            container(id: "arbitrary-job", labels: ["example.worker.job": "job-44"]),
            container(id: "wrong-agent-value", labels: ["com.micropod.agent": "TRUE"]),
            container(id: "blank-cuttlefish-job", labels: ["com.cuttlefish.job": "   "]),
        ]

        XCTAssertEqual(store.agentWorkloadCount, 2)
    }

    func testLocalImageInventoryCountAndStoredBytesSaturateOnOverflow() {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        store.images = [
            image(id: "large", sizeBytes: UInt64.max - 5),
            image(id: "overflowing", sizeBytes: 10),
        ]

        XCTAssertEqual(store.localImageCount, 2)
        XCTAssertEqual(store.localImageBytes, UInt64.max)
    }

    func testBootstrapLoadsLocalImagesWithoutVisitingImagesTab() async throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        _ = try await fixture.client.run(ContainerCommandFactory.pullImage("alpine:latest"))
        let store = AppStore(dependencies: AppDependencies(client: fixture.client))
        defer { store.stopPollers() }

        store.bootstrap()
        try await waitUntil(timeout: .seconds(5)) { store.localImageCount == 1 }

        XCTAssertTrue(store.hasLoadedImages)
        XCTAssertEqual(store.images.first?.names, ["alpine:latest"])
    }

    func testImageInventoryBecomesUnavailableWhenRuntimeStops() async throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        _ = try await fixture.client.run(ContainerCommandFactory.pullImage("alpine:latest"))
        let store = makeRunningStore(client: fixture.client)

        await store.refreshImages()
        XCTAssertTrue(store.hasLoadedImages)

        store.systemStatus?.status = "stopped"
        await store.refreshImages()

        XCTAssertFalse(store.hasLoadedImages)
    }

    func testRecentActivityIsNewestFirstAndBounded() {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        store.recordActivity("test", "first")
        store.recordActivity("test", "second")
        store.recordActivity("test", "third")

        XCTAssertEqual(store.recentActivity(limit: 2).map(\.message), ["third", "second"])
        XCTAssertEqual(store.recentActivity(limit: 20).map(\.message), ["third", "second", "first"])
        XCTAssertTrue(store.recentActivity(limit: 0).isEmpty)
        XCTAssertTrue(store.recentActivity(limit: -1).isEmpty)
    }

    func testComposeCancellationCancelsRegisteredReadinessTask() async throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = makeRunningStore(client: fixture.client)
        let composeFile = fixture.directory.appendingPathComponent("docker-compose.yml")
        try """
        name: slow-stack
        services:
          slow-service:
            image: alpine:latest
            container_name: slow-service
            healthcheck:
              test: ["CMD", "true"]
              start_period: 1s
          dependent:
            image: busybox:latest
            depends_on:
              slow-service:
                condition: service_healthy
        """.write(to: composeFile, atomically: true, encoding: .utf8)
        let spec = try await store.dependencies.compose.parse(url: composeFile)
        let plan = try store.dependencies.compose.plan(spec: spec)
        XCTAssertTrue(plan.steps.contains { if case .readiness = $0 { true } else { false } })

        let stream = store.composeUpStream(plan: plan)
        let consumer = Task { () -> Bool in
            do {
                for try await _ in stream {}
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        guard let operationID = store.operations.last(where: { $0.kind == .compose })?.id else {
            consumer.cancel()
            return XCTFail("Expected a Compose operation")
        }

        try await waitUntil(timeout: .seconds(8)) {
            store.operationRegistry.operation(operationID)?.events.contains {
                $0 == "Waiting for slow-service to be ready…"
            } == true
        }
        store.cancelOperation(operationID)
        try await Task.sleep(for: .milliseconds(1_500))
        let commandTrace = (try? String(contentsOf: fixture.traceURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(
            commandTrace.split(separator: "\n").contains { $0.hasPrefix("exec ") },
            "The Compose producer continued after cancellation: \(commandTrace)")
        try await waitUntil { store.operationRegistry.operation(operationID)?.status == .cancelled }

        XCTAssertEqual(store.operationRegistry.operation(operationID)?.status, .cancelled)
        let consumerSawCancellation = await consumer.value
        XCTAssertTrue(consumerSawCancellation)
    }

    /// The runtime liveness probe (`container list` under an 8s ceiling)
    /// must succeed against a healthy mock runtime and fail fast against a
    /// dead one — it drives the wedged-apiserver self-heal path.
    func testLivenessProbeSucceedsAgainstHealthyRuntime() async throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = makeRunningStore(client: fixture.client)
        try await store.dependencies.system.livenessProbe()
    }

    func testLivenessProbeFailsAgainstDeadRuntime() async {
        let store = makeRunningStore(client: AppTestCLI.makeFailing())
        do {
            try await store.dependencies.system.livenessProbe()
            XCTFail("liveness probe should throw when the CLI is unusable")
        } catch {}
    }

    /// Pollers + supervisor each call refreshSystemStatus — the second call
    /// inside the freshness window must reuse the first result instead of
    /// spawning another `container system status`.
    func testSystemStatusRefreshCoalescesWithinFreshnessWindow() async throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = AppStore(dependencies: AppDependencies(client: fixture.client))
        defer { store.stopPollers() }

        await store.refreshSystemStatus()
        await store.refreshSystemStatus()
        var statusCalls = statusCallCount(in: fixture.traceURL)
        XCTAssertEqual(statusCalls, 1)

        await store.refreshSystemStatus(force: true)
        statusCalls = statusCallCount(in: fixture.traceURL)
        XCTAssertEqual(statusCalls, 2)
    }

    /// Concurrent callers share a single in-flight status spawn.
    func testConcurrentSystemStatusRefreshSharesOneSpawn() async throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = AppStore(dependencies: AppDependencies(client: fixture.client))
        defer { store.stopPollers() }

        async let first: Void = store.refreshSystemStatus()
        async let second: Void = store.refreshSystemStatus()
        _ = await (first, second)

        XCTAssertEqual(statusCallCount(in: fixture.traceURL), 1)
    }

    private func statusCallCount(in traceURL: URL) -> Int {
        let trace = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? ""
        return trace.split(separator: "\n").filter { $0 == "system status --format json" }.count
    }

    private func container(id: String, labels: [String: String]) -> Micropod_V1_Container {
        var container = Micropod_V1_Container()
        container.id = id
        container.labels = labels
        return container
    }

    private func image(id: String, sizeBytes: UInt64) -> Micropod_V1_Image {
        var image = Micropod_V1_Image()
        image.id = id
        image.sizeBytes = sizeBytes
        return image
    }
}
