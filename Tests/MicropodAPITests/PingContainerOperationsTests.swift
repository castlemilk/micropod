import Foundation
import MicropodCore
import MicropodRuntime
import SwiftProtobuf
import XCTest

@testable import MicropodAPI

/// Ping's `container_operations` (field 14) on the wire.
final class PingContainerOperationsTests: XCTestCase {
    func testQueueSnapshotMapsToThePingMessage() {
        let queue = APIHandlers.containerOperations(
            .init(inFlight: 3, abandoned: 2, waiting: 1, oldestAge: .milliseconds(61_250)))
        XCTAssertEqual(queue.depth, 4)
        XCTAssertEqual(queue.inFlight, 3)
        XCTAssertEqual(queue.abandoned, 2)
        XCTAssertEqual(queue.waiting, 1)
        XCTAssertEqual(queue.oldestAgeMs, 61_250)
        XCTAssertEqual(APIHandlers.containerOperations(.init()), Micropod_V1_ContainerOperationQueue())
    }

    func testItIsANewFieldBesideTheExistingOnes() throws {
        var response = Micropod_V1_PingResponse()
        response.status = "running"
        response.containerOperations = APIHandlers.containerOperations(
            .init(inFlight: 1, abandoned: 1, oldestAge: .seconds(70)))
        let json = try response.jsonString()
        XCTAssertTrue(json.contains("\"containerOperations\""), json)
        XCTAssertTrue(json.contains("\"oldestAgeMs\":\"70000\""), json)
        // Field 1 (status) then field 14, length-delimited: tag (14 << 3) | 2.
        let bytes: [UInt8] = try response.serializedBytes()
        XCTAssertEqual(bytes.first, 0x0A)
        XCTAssertTrue(bytes.contains(0x72), "\(bytes)")
        XCTAssertFalse(Micropod_V1_PingResponse().hasContainerOperations, "unset unless a native server sets it")
    }
}
