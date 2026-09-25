import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Guards around native `create` that need no live runtime:
///  - a failed create removes the clone images it made, *unless* the
///    failure is `already_exists` — then the clones belong to the container
///    that won the race and must survive a replayed create;
///  - `no_pull` refuses a missing image with a `notFound:`-prefixed message
///    naming the platform, which the Connect table maps to `not_found`.
final class NativeCreateGuardsTests: XCTestCase {

    func testAlreadyExistsKeepsTheWinnersClones() {
        XCTAssertTrue(
            NativeContainerService.isAlreadyExists(
                MicropodError.message("alreadyExists: container with ID job-1 already exists")))
        // The apiserver's own duplicate-id refusal (`ContainerizationError(.exists, …)`
        // arrives as `exists: …` over XPC) must keep the winner's clones too.
        XCTAssertTrue(
            NativeContainerService.isAlreadyExists(
                MicropodError.message("exists: container already exists: job-1")))
        XCTAssertFalse(
            NativeContainerService.isAlreadyExists(
                MicropodError.message("notFound: image x not present locally for linux/arm64")))
        XCTAssertFalse(NativeContainerService.isAlreadyExists(MicropodError.transport("connection invalidated")))
        XCTAssertFalse(
            NativeContainerService.isAlreadyExists(
                MicropodError.message("failed to clone volume 'cache' (/x.img): No such file or directory")))
    }

    /// Two creates for the same id that both pass the duplicate-id list check
    /// each try to place `<root>/<id>/<vol>.img`. The second placement must
    /// fail `already_exists` and leave the first clone — possibly a running
    /// container's live block device — exactly as it was, never rename over it.
    func testCloneVolumeImageNeverReplacesAnExistingClone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-clone-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("MICROPOD_VOLUME_CLONE_ROOT", root.path, 1)
        defer { unsetenv("MICROPOD_VOLUME_CLONE_ROOT") }
        let golden = root.appendingPathComponent("golden.img")
        try Data("golden".utf8).write(to: golden)

        let placed = try NativeContainerService.cloneVolumeImage(
            source: golden.path, containerID: "job-9", volume: "cache")
        XCTAssertEqual(placed, root.appendingPathComponent("job-9/cache.img").path)
        // The winner started and wrote into its clone.
        try Data("winner-writes".utf8).write(to: URL(fileURLWithPath: placed))

        XCTAssertThrowsError(
            try NativeContainerService.cloneVolumeImage(source: golden.path, containerID: "job-9", volume: "cache")
        ) { error in
            XCTAssertTrue(NativeContainerService.isAlreadyExists(error), "\(error)")
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "already_exists")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: placed)), Data("winner-writes".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("job-9").path),
            ["cache.img"], "no staging file left next to the winner's clone")
    }

    func testNoPullRefusalNamesImageAndPlatformAsNotFound() {
        let error = ImagesServiceClient.notPresentLocally(
            reference: "ghost/none:1",
            platform: .object(["os": .string("linux"), "architecture": .string("arm64")]))
        XCTAssertEqual(
            error.localizedDescription, "notFound: image ghost/none:1 not present locally for linux/arm64")
        XCTAssertEqual(ConnectCodeMapping.code(for: error), "not_found")

        let variant = ImagesServiceClient.notPresentLocally(
            reference: "ghost/none:1",
            platform: .object([
                "os": .string("linux"), "architecture": .string("arm64"), "variant": .string("v8"),
            ]))
        XCTAssertTrue(variant.localizedDescription.hasSuffix("for linux/arm64/v8"), variant.localizedDescription)

        let anyPlatform = ImagesServiceClient.notPresentLocally(reference: "ghost/none:1", platform: nil)
        XCTAssertEqual(
            anyPlatform.localizedDescription, "notFound: image ghost/none:1 not present locally for any platform")
    }
}
