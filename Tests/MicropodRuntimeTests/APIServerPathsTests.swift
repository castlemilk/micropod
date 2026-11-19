import XCTest

@testable import MicropodRuntime

/// container-apiserver's ping reports its app root as a file URL
/// (`URL.absoluteString`); bundle and volume paths are built from the
/// decoded filesystem path, never from the URL text.
final class APIServerPathsTests: XCTestCase {
    func testFileURLRootsBecomeFilesystemPaths() {
        XCTAssertEqual(
            APIServerClient.filesystemPath(
                "file:///Users/x/Library/Application%20Support/com.apple.container/"),
            "/Users/x/Library/Application Support/com.apple.container")
        XCTAssertEqual(
            APIServerClient.filesystemPath(
                "file:///private/var/db/micropod-runtime/Library/Application%20Support/com.apple.container/"),
            "/private/var/db/micropod-runtime/Library/Application Support/com.apple.container")
    }

    func testPlainPathsAreKeptAndEmptyIsNothing() {
        XCTAssertEqual(APIServerClient.filesystemPath("/opt/container"), "/opt/container")
        XCTAssertNil(APIServerClient.filesystemPath(""))
    }
}
