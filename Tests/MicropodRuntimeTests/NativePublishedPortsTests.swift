import MicropodCore
import NIOCore
import NIOPosix
import XCTest

@testable import MicropodRuntime

/// The apiserver cannot parse an empty host address, so an empty host IP must
/// reach it as the all-interfaces default rather than as "".
final class NativePublishedPortsTests: XCTestCase {
    func testRevocationClosesActiveClientsAndRejectsLateConnections() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let server = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        defer { server.close(promise: nil) }
        let address = try XCTUnwrap(server.localAddress)
        let clients = NativePortClients()
        let active = try await ClientBootstrap(group: group).connect(to: address).get()
        defer { active.close(promise: nil) }
        XCTAssertTrue(clients.track(active))
        let closed = expectation(description: "active client closed")
        active.closeFuture.whenComplete { _ in closed.fulfill() }
        clients.close()
        await fulfillment(of: [closed], timeout: 2)
        let late = try await ClientBootstrap(group: group).connect(to: address).get()
        defer { late.close(promise: nil) }
        XCTAssertFalse(clients.track(late))
    }

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
