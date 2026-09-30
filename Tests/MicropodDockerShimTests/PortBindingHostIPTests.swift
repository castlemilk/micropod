import MicropodCore
import XCTest

@testable import MicropodDockerShim

/// Docker clients send `HostIp: ""` for "all interfaces" (`docker run -p 5432`,
/// and every port testcontainers publishes). The shim used to pass the empty
/// string through as the host address, and the apiserver rejected the create
/// with "unableToParse".
final class PortBindingHostIPTests: XCTestCase {
    private static func ports(_ bindings: [DockerPortBinding]) throws -> [PortSpec] {
        var body = DockerCreateRequest(Image: "alpine:3.22")
        var hostConfig = DockerHostConfig()
        hostConfig.PortBindings = ["5432/tcp": bindings]
        body.HostConfig = hostConfig
        return try Router.buildRunRequest(from: body, name: nil).publishedPorts
    }

    func testEmptyHostIPIsUnset() throws {
        let ports = try Self.ports([DockerPortBinding(HostIp: "", HostPort: "")])
        XCTAssertEqual(ports.count, 1)
        XCTAssertNil(ports[0].hostIP)
        XCTAssertGreaterThan(ports[0].hostPort, 0)
        XCTAssertEqual(ports[0].containerPort, 5432)
    }

    func testMissingHostIPIsUnset() throws {
        XCTAssertNil(try Self.ports([DockerPortBinding(HostIp: nil, HostPort: "0")])[0].hostIP)
    }

    func testExplicitHostIPIsKept() throws {
        let ports = try Self.ports([DockerPortBinding(HostIp: "127.0.0.1", HostPort: "55432")])
        XCTAssertEqual(ports[0].hostIP, "127.0.0.1")
        XCTAssertEqual(ports[0].hostPort, 55432)
    }
}
