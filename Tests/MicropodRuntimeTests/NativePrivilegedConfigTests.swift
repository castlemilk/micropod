import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Native backend: `privileged` becomes explicit empty `readonlyPaths` /
/// `maskedPaths` (what `container run --read-only-path NONE --masked-path
/// NONE` records), and unprivileged creates keep the runtime defaults by
/// emitting neither key.
final class NativePrivilegedConfigTests: XCTestCase {
    func testPrivilegedClearsDefaultPaths() {
        let paths = NativeConfigBuilder.privilegedPaths(ContainerRunRequest(image: "docker:dind", privileged: true))
        XCTAssertEqual(paths["readonlyPaths"], .array([]))
        XCTAssertEqual(paths["maskedPaths"], .array([]))
    }

    func testUnprivilegedKeepsRuntimeDefaults() {
        XCTAssertTrue(NativeConfigBuilder.privilegedPaths(ContainerRunRequest(image: "alpine:3.20")).isEmpty)
    }

    func testPrivilegedCapAddIsAll() {
        let request = ContainerRunRequest(image: "docker:dind", capAdd: ["CAP_NET_ADMIN"], privileged: true)
        XCTAssertEqual(NativeConfigBuilder.normalizeCapabilities(request.effectiveCapAdd), [.string("ALL")])
    }
}
