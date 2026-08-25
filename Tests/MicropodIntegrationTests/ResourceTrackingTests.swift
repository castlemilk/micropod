import MicropodCore
import XCTest

final class ResourceTrackingTests: XCTestCase {
    // MARK: - Volumes

    func testVolumeCreateListDelete() async throws {
        try await withMockServices { mock in
            try await mock.volumes.create(name: "data", size: "100M")
            try await mock.volumes.create(name: "small")

            let volumes = try await mock.volumes.list()
            XCTAssertEqual(volumes.count, 2)

            let data = volumes.first { $0.id == "data" }
            XCTAssertEqual(data?.driver, "local")
            XCTAssertEqual(data?.format, "ext4")
            XCTAssertEqual(data?.sizeBytes, 104_857_600, "100M volume should report 104857600 bytes")
            let small = volumes.first { $0.id == "small" }
            XCTAssertEqual(small?.sizeBytes, 52_428_800, "default size is 50M")

            try await mock.volumes.delete("data")
            let remaining = try await mock.volumes.list()
            XCTAssertEqual(remaining.count, 1)
            XCTAssertEqual(remaining[0].id, "small")
        }
    }

    func testVolumePrune() async throws {
        try await withMockServices { mock in
            try await mock.volumes.create(name: "v1")
            try await mock.volumes.create(name: "v2")
            let report = try await mock.volumes.prune()
            XCTAssertFalse(report.isEmpty)
            let volumes = try await mock.volumes.list()
            XCTAssertTrue(volumes.isEmpty)
        }
    }

    func testDiskUsageTracksVolumeGrowth() async throws {
        try await withMockServices { mock in
            let before = try await mock.system.diskUsage()
            XCTAssertEqual(before.volumes.sizeBytes, 0)

            try await mock.volumes.create(name: "a", size: "100M")
            var usage = try await mock.system.diskUsage()
            XCTAssertEqual(usage.volumes.sizeBytes, 104_857_600)
            XCTAssertEqual(usage.volumes.total, 1)

            try await mock.volumes.create(name: "b", size: "50M")
            usage = try await mock.system.diskUsage()
            XCTAssertEqual(usage.volumes.sizeBytes, 104_857_600 + 52_428_800)
            XCTAssertEqual(usage.volumes.total, 2)
        }
    }

    // MARK: - Networks

    func testNetworkCreateInternalWithSubnet() async throws {
        try await withMockServices { mock in
            try await mock.networks.create(name: "isolated", internal: true, subnet: "10.5.0.0/24")

            let networks = try await mock.networks.list()
            XCTAssertEqual(networks.count, 1)
            let network = networks[0]
            XCTAssertEqual(network.id, "isolated")
            XCTAssertEqual(network.mode, "hostOnly", "real CLI reports hostOnly for --internal")
            XCTAssertEqual(network.ipv4Subnet, "10.5.0.0/24")
            XCTAssertEqual(network.ipv4Gateway, "10.5.0.1")
            XCTAssertFalse(network.builtin)
            XCTAssertEqual(network.plugin, "container-network-vmnet")
        }
    }

    func testNetworkBuiltinFlagOnlyForDefault() async throws {
        try await withMockServices { mock in
            try await mock.networks.create(name: "default")
            try await mock.networks.create(name: "custom")

            let networks = try await mock.networks.list()
            XCTAssertTrue(networks.first { $0.id == "default" }?.builtin == true)
            XCTAssertTrue(networks.first { $0.id == "custom" }?.builtin == false)
        }
    }

    func testNetworkDeleteAndPrune() async throws {
        try await withMockServices { mock in
            try await mock.networks.create(name: "default")
            try await mock.networks.create(name: "custom")

            try await mock.networks.delete("custom")
            var remaining = try await mock.networks.list()
            XCTAssertEqual(remaining.map(\.id), ["default"])

            try await mock.networks.create(name: "temp")
            _ = try await mock.networks.prune()
            remaining = try await mock.networks.list()
            XCTAssertEqual(remaining.map(\.id), ["default"], "builtin network survives prune")
        }
    }

    func testContainerAttachesToNetwork() async throws {
        try await withMockServices { mock in
            try await mock.networks.create(name: "app-net")
            let id = try await mock.runContainer(name: "web")
            let container = try await mock.containers.list().first { $0.id == id }
            XCTAssertEqual(container?.networks, ["default"])
            XCTAssertFalse(container?.ipv4Address.isEmpty ?? true)
        }
    }

    // MARK: - Stats / resource tracking

    func testStatsSamplerComputesCpuPercentBetweenSamples() async throws {
        try await withMockServices { mock in
            _ = try await mock.runContainer(name: "web")

            let first = try await mock.stats.snapshot()
            XCTAssertEqual(first.containers.count, 1)
            XCTAssertGreaterThan(first.containers[0].memoryUsedBytes, 0)
            XCTAssertEqual(first.containers[0].pids, 2)
            XCTAssertEqual(first.containers[0].cpuPercent, 0, "no delta on first sample")

            try await Task.sleep(for: .milliseconds(200))

            let second = try await mock.stats.snapshot()
            let stats = second.containers.first { $0.id == first.containers[0].id }
            XCTAssertGreaterThan(stats?.cpuPercent ?? 0, 0, "second sample should compute a CPU delta")
            XCTAssertGreaterThan(stats?.networkRxBytes ?? 0, 0)
            XCTAssertGreaterThan(stats?.blockWriteBytes ?? 0, 0)
            XCTAssertFalse(second.sampledAt.isEmpty)
        }
    }

    func testStatsOnlyIncludeRunningContainers() async throws {
        try await withMockServices { mock in
            let running = try await mock.runContainer(name: "keep")
            let stopped = try await mock.runContainer(name: "gone")
            try await mock.containers.stop(stopped)

            let snapshot = try await mock.stats.snapshot()
            let ids = snapshot.containers.map(\.id)
            XCTAssertEqual(ids, [running], "stopped containers must not appear in stats")
        }
    }

    func testStatsForgetRemovedContainers() async throws {
        try await withMockServices { mock in
            let id = try await mock.runContainer(name: "web")
            _ = try await mock.stats.snapshot()
            try await mock.containers.delete(id, force: true)

            // Deleted container must not leak into the sampler's previous map.
            let snapshot = try await mock.stats.snapshot()
            XCTAssertTrue(snapshot.containers.isEmpty)
        }
    }

    // MARK: - Registries

    func testRegistryLoginLogoutList() async throws {
        try await withMockServices { mock in
            let logins = try await mock.registries.list()
            XCTAssertTrue(logins.isEmpty)

            try await mock.registries.login(server: "ghcr.io", username: "ben", password: "secret")
            let afterLogin = try await mock.registries.list()
            XCTAssertEqual(afterLogin.count, 1)
            XCTAssertEqual(afterLogin[0].server, "ghcr.io")
            XCTAssertEqual(afterLogin[0].username, "ben")
            XCTAssertEqual(afterLogin[0].scheme, "https")

            try await mock.registries.logout("ghcr.io")
            let afterLogout = try await mock.registries.list()
            XCTAssertTrue(afterLogout.isEmpty)
        }
    }

    // MARK: - Image tracking

    func testImagePullThenDelete() async throws {
        try await withMockServices { mock in
            let images = try await mock.images.list()
            XCTAssertTrue(images.isEmpty)

            var events: [ProgressEvent] = []
            for try await event in mock.images.pull("alpine:3.20", platform: nil) {
                events.append(event)
            }
            XCTAssertFalse(events.isEmpty)
            XCTAssertTrue(
                events.contains { $0.stageName == "Pull complete" },
                "mock emits [3/3] Pull complete before the Digest line")
            XCTAssertTrue(events.contains { $0.stage == 1 && $0.totalStages == 3 })

            let afterPull = try await mock.images.list()
            XCTAssertEqual(afterPull.count, 1)
            XCTAssertEqual(afterPull[0].names, ["alpine:3.20"])
            XCTAssertEqual(afterPull[0].sizeBytes, 209_715_200)

            try await mock.images.delete("alpine:3.20", force: false)
            let afterDelete = try await mock.images.list()
            XCTAssertTrue(afterDelete.isEmpty)
        }
    }

    func testImagePushStreams() async throws {
        try await withMockServices { mock in
            var events: [ProgressEvent] = []
            for try await event in mock.images.push("alpine:3.20", platform: nil) {
                events.append(event)
            }
            XCTAssertTrue(events.contains { $0.stage == 2 })
        }
    }

    func testImageTagAndInspect() async throws {
        try await withMockServices { mock in
            try await mock.images.tag(source: "nginx:1.27", target: "registry.local/nginx:prod")
            let images = try await mock.images.list()
            XCTAssertEqual(images.map(\.names).flatMap { $0 }, ["registry.local/nginx:prod"])

            let inspected = try await mock.images.inspect("registry.local/nginx:prod")
            XCTAssertTrue(String(data: inspected, encoding: .utf8)?.contains("nginx:prod") ?? false)
        }
    }

    func testImagePrune() async throws {
        try await withMockServices { mock in
            for try await _ in mock.images.pull("alpine:3.20", platform: nil) {}
            let report = try await mock.images.prune(danglingOnly: false)
            XCTAssertFalse(report.isEmpty)
            let images = try await mock.images.list()
            XCTAssertTrue(images.isEmpty)
        }
    }
}
