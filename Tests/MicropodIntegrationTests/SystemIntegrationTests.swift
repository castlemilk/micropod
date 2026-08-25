import MicropodCore
import XCTest

final class SystemIntegrationTests: XCTestCase {
    func testStatusReportsRuntimeAndVersions() async throws {
        try await withMockServices { mock in
            let status = try await mock.system.status()
            XCTAssertEqual(status.status, "running")
            XCTAssertEqual(status.cliVersion, "1.2.3")
            XCTAssertTrue(status.apiServerVersion.contains("1.2.3"))
            XCTAssertEqual(status.appRoot, "/mock/app-root/")
            XCTAssertEqual(status.installRoot, "/usr/local/")
        }
    }

    func testSystemVersionDecodesArray() async throws {
        try await withMockServices { mock in
            let version = try await mock.system.cliVersion()
            XCTAssertEqual(version, "1.2.3")
        }
    }

    func testDiskUsageReflectsLiveState() async throws {
        try await withMockServices { mock in
            var usage = try await mock.system.diskUsage()
            XCTAssertEqual(usage.containers.sizeBytes, 0)
            XCTAssertEqual(usage.volumes.sizeBytes, 0)

            _ = try await mock.runContainer(name: "web")
            try await mock.volumes.create(name: "data", size: "100M")

            usage = try await mock.system.diskUsage()
            XCTAssertEqual(usage.containers.sizeBytes, 104_857_600)
            XCTAssertEqual(usage.containers.active, 1)
            XCTAssertEqual(usage.containers.total, 1)
            XCTAssertEqual(usage.volumes.sizeBytes, 104_857_600)
            XCTAssertEqual(usage.totalReclaimableBytes, 0)

            try await mock.containers.stop("web")
            usage = try await mock.system.diskUsage()
            XCTAssertEqual(usage.containers.active, 0)
            XCTAssertEqual(usage.containers.reclaimableBytes, 104_857_600)
            XCTAssertEqual(usage.totalReclaimableBytes, 104_857_600)
        }
    }

    func testSystemLogsReturnContent() async throws {
        try await withMockServices { mock in
            let logs = try await mock.system.systemLogs(last: "10m")
            XCTAssertTrue(logs.contains("mock system service log"))
        }
    }

    func testRuntimeStartAndStopAreNoopsWhenRunning() async throws {
        try await withMockServices { mock in
            try await mock.system.start()
            try await mock.system.stop()
        }
    }

    func testInstallRecommendedKernelStreams() async throws {
        try await withMockServices { mock in
            var output = ""
            for try await chunk in mock.system.installRecommendedKernel() {
                output += chunk
            }
            XCTAssertTrue(output.contains("kernel set to recommended"))
        }
    }

    func testClientAvailability() async throws {
        let (client, stateDir) = try MockContainerCLI.makeClient()
        defer { MockContainerCLI.cleanUp(stateDir) }
        XCTAssertTrue(client.isAvailable())

        let missing = ContainerCLIClient(
            executableURL: URL(fileURLWithPath: "/nonexistent/container"))
        XCTAssertFalse(missing.isAvailable())
    }
}
