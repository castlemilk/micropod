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
        XCTAssertFalse(
            NativeContainerService.isAlreadyExists(
                MicropodError.message("notFound: image x not present locally for linux/arm64")))
        XCTAssertFalse(NativeContainerService.isAlreadyExists(MicropodError.transport("connection invalidated")))
        XCTAssertFalse(
            NativeContainerService.isAlreadyExists(
                MicropodError.message("failed to clone volume 'cache' (/x.img): No such file or directory")))
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
