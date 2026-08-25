import XCTest
@testable import MicropodCore

final class UsageServiceTests: XCTestCase {
    func testReferenceNormalization() {
        XCTAssertEqual(UsageService.normalize("docker.io/library/alpine:3.20"), "alpine:3.20")
        XCTAssertEqual(UsageService.normalize("alpine:3.20"), "alpine:3.20")
        XCTAssertEqual(UsageService.normalize("library/alpine:3.20"), "alpine:3.20")
        XCTAssertEqual(UsageService.normalize("docker.io/testcontainers/ryuk:0.8.1"), "testcontainers/ryuk:0.8.1")
        XCTAssertEqual(UsageService.normalize("testcontainers/ryuk:0.8.1"), "testcontainers/ryuk:0.8.1")
        XCTAssertEqual(
            UsageService.normalize("docker.io/library/postgres@sha256:abc"), "postgres")
        XCTAssertEqual(UsageService.normalize("ALPINE:3.20"), "alpine:3.20")
    }

    func testReportMarksInUseImagesAndVolumes() async throws {
        let services = try MockContainerCLI.makeServices()

        // Container on alpine + a volume mount via create flags.
        for try await _ in services.images.pull("alpine:3.20") {}
        _ = try await services.containers.run(
            ContainerRunRequest(
                image: "alpine:3.20", name: "usage-web", volumes: ["vol-in-use:/data"],
                arguments: ["sleep", "60"]))
        _ = try await services.volumes.create(name: "vol-in-use", size: nil, labels: [], options: [])
        _ = try await services.volumes.create(name: "vol-orphan", size: nil, labels: [], options: [])

        let usage = UsageService(
            containers: services.containers, images: services.images, volumes: services.volumes)
        let report = try await usage.report()

        let alpine = report.images.first { $0.image.names.contains { $0.contains("alpine") } }
        XCTAssertNotNil(alpine)
        XCTAssertTrue(alpine!.inUse, "alpine is used by the running container")
        XCTAssertEqual(alpine!.usedByContainerIDs.count, 1)

        let inUseVolume = report.volumes.first { $0.volume.id == "vol-in-use" }
        let orphanVolume = report.volumes.first { $0.volume.id == "vol-orphan" }
        XCTAssertNotNil(inUseVolume)
        XCTAssertNotNil(orphanVolume)
        XCTAssertTrue(inUseVolume!.inUse, "mounted volume must count as in use")
        XCTAssertFalse(orphanVolume!.inUse, "unreferenced volume must be reclaimable")
        XCTAssertGreaterThan(report.reclaimableVolumeBytes, 0)

        // The ryuk image (pulled, no containers using it) is reclaimable.
        for try await _ in services.images.pull("testcontainers/ryuk:0.8.1") {}
        let usageAfterPull = try await usage.report()
        let ryuk = usageAfterPull.images.first { $0.image.names.contains { $0.contains("ryuk") } }
        XCTAssertNotNil(ryuk)
        XCTAssertFalse(ryuk!.inUse)
    }

    func testStoppedContainersCounted() async throws {
        let services = try MockContainerCLI.makeServices()
        _ = try await services.containers.run(
            ContainerRunRequest(image: "alpine:3.20", name: "usage-stopped", arguments: ["sleep", "60"]))
        try await services.containers.stop("usage-stopped", timeout: 0)
        _ = try await services.containers.run(
            ContainerRunRequest(image: "alpine:3.20", name: "usage-running", arguments: ["sleep", "60"]))

        let usage = UsageService(
            containers: services.containers, images: services.images, volumes: services.volumes)
        let report = try await usage.report()
        XCTAssertEqual(report.stoppedContainerCount, 1)
        XCTAssertEqual(report.containers.filter { $0.running }.count, 1)
    }
}
