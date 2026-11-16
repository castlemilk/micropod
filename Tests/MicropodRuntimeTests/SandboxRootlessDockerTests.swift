import Foundation
import XCTest

@testable import MicropodRuntime

final class SandboxRootlessDockerTests: XCTestCase {
    func testIsOptInAndRejectsHostExposureAndCheckpoints() throws {
        var options = SandboxVM.Options(base: .image("example@sha256:abc"))
        XCTAssertFalse(options.rootlessDocker)
        options.rootlessDocker = true
        XCTAssertNoThrow(try SandboxVM.validateRootlessDocker(options))
        options.mounts = ["/host:/guest:ro"]
        XCTAssertThrowsError(try SandboxVM.validateRootlessDocker(options))
        options.mounts = []
        options.exposeHost = [5555]
        XCTAssertThrowsError(try SandboxVM.validateRootlessDocker(options))
        options.exposeHost = []
        options.saveAs = "saved"
        XCTAssertThrowsError(try SandboxVM.validateRootlessDocker(options))
        options.saveAs = nil
        options.base = .checkpoint("saved")
        XCTAssertThrowsError(try SandboxVM.validateRootlessDocker(options))
    }
}

extension SandboxRootlessDockerTests {
    func testRejectsPublishedPortsAndProxySecrets() {
        var options = SandboxVM.Options(base: .image("fixture"))
        options.rootlessDocker = true
        options.ports = [.init(hostPort: 1234, guestPort: 5678)]
        XCTAssertThrowsError(try SandboxVM.validateRootlessDocker(options))
        options.ports = []
        options.egress = .init(allowHosts: ["github.com"])
        XCTAssertThrowsError(try SandboxVM.validateRootlessDocker(options))
    }
}
