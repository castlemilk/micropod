import MicropodCore
import XCTest

final class MachineServiceTests: XCTestCase {
    func testMachineLifecycleAgainstMock() async throws {
        try await withMockServices { mock in
            let service = MachineService(client: mock.client)

            // Empty machine list.
            let empty = try await service.list()
            XCTAssertTrue(empty.isEmpty)

            // Create + list.
            try await service.create(image: "alpine:3.22", name: "devbox", cpus: "4", memory: "8gb")
            let machines = try await service.list()
            XCTAssertEqual(machines.count, 1)
            XCTAssertEqual(machines[0].name, "devbox")
            XCTAssertEqual(machines[0].cpus, 4)
            XCTAssertEqual(machines[0].memory, "8gb")

            // Delete.
            try await service.delete("devbox")
            let after = try await service.list()
            XCTAssertTrue(after.isEmpty)
        }
    }

    func testSystemPropertiesParsed() async throws {
        try await withMockServices { mock in
            let service = MachineService(client: mock.client)
            let props = try await service.properties()
            XCTAssertNotNil(props["machine"])
            XCTAssertEqual(props["machine"]?["cpus"], .number(6))
            XCTAssertEqual(props["machine"]?["homeMount"], .string("rw"))
            XCTAssertEqual(props["build"]?["rosetta"], .bool(true))
            XCTAssertNotNil(props["kernel"]?["url"])
        }
    }
}
