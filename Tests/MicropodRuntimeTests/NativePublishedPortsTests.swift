import MicropodCore
import XCTest

@testable import MicropodRuntime

/// The apiserver cannot parse an empty host address, so an empty host IP must
/// reach it as the all-interfaces default rather than as "".
final class NativePublishedPortsTests: XCTestCase {
    private static func address(_ hostIP: String?) throws -> JSONValue? {
        let ports = try NativeConfigBuilder.publishedPorts([
            PortSpec(hostPort: 55432, containerPort: 5432, hostIP: hostIP)
        ])
        guard case .object(let port) = ports.first else { return nil }
        return port["hostAddress"]
    }

    func testEmptyHostIPBecomesAllInterfaces() throws {
        XCTAssertEqual(try Self.address(""), .string("0.0.0.0"))
    }

    func testNilHostIPBecomesAllInterfaces() throws {
        XCTAssertEqual(try Self.address(nil), .string("0.0.0.0"))
    }

    func testExplicitHostIPIsKept() throws {
        XCTAssertEqual(try Self.address("127.0.0.1"), .string("127.0.0.1"))
    }
}
