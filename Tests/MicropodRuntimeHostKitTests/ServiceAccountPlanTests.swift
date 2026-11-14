import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntimeHostKit

final class ServiceAccountPlanTests: XCTestCase {
    func testAllocatesSeparateUnusedIDsAndRefusesExhaustionOrRootOwner() throws {
        let identity = try ServiceAccountPlan.allocate(
            ownerUID: 501, occupiedUIDs: [400, 401], occupiedGIDs: [400, 402])
        XCTAssertEqual(identity.serviceUID, 402)
        XCTAssertEqual(identity.serviceGID, 401)
        XCTAssertThrowsError(try ServiceAccountPlan.allocate(ownerUID: 0, occupiedUIDs: [], occupiedGIDs: []))
        XCTAssertThrowsError(
            try ServiceAccountPlan.allocate(
                ownerUID: 501, occupiedUIDs: Set(IsolatedRuntimePolicy.userIDs), occupiedGIDs: []))
    }
    func testNeverAdoptsForeignOrLoginEnabledAccount() throws {
        let identity = try ServiceAccountPlan.allocate(ownerUID: 501, occupiedUIDs: [], occupiedGIDs: [])
        func record(guid: UUID, disabled: Bool = true) -> ServiceAccountRecord {
            .init(
                name: IsolatedRuntimePolicy.accountName, uid: identity.serviceUID, gid: identity.serviceGID, guid: guid,
                home: IsolatedRuntimePolicy.home.path, shell: "/usr/bin/false", comment: identity.accountComment,
                hidden: true, loginDisabled: disabled)
        }
        try ServiceAccountPlan.verify(record(guid: identity.accountGUID), identity: identity)
        XCTAssertThrowsError(try ServiceAccountPlan.verify(record(guid: UUID()), identity: identity))
        XCTAssertThrowsError(
            try ServiceAccountPlan.verify(record(guid: identity.accountGUID, disabled: false), identity: identity))
    }
    func testIdentityIsStableAcrossJournalRoundTripAndRejectsUnprotectedMetadata() throws {
        let identity = try ServiceAccountPlan.allocate(ownerUID: 501, occupiedUIDs: [], occupiedGIDs: [])
        XCTAssertEqual(
            try JSONDecoder().decode(IsolatedRuntimeIdentity.self, from: JSONEncoder().encode(identity)), identity)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("identity.json")
        try RuntimeDurableFile.write(identity, to: path)
        XCTAssertThrowsError(try IsolatedRuntimeIdentity.readRootOwned(at: path))
    }
}

private final class DirectoryFixture: ServiceAccountDirectory, @unchecked Sendable {
    var userRecord: ServiceAccountRecord?
    var groupRecord: ServiceGroupRecord?
    var failUserCreation = false
    var groupCreates = 0
    var userCreates = 0
    func user() throws -> ServiceAccountRecord? { userRecord }
    func group() throws -> ServiceGroupRecord? { groupRecord }
    func occupiedIDs() throws -> (users: Set<UInt32>, groups: Set<UInt32>) { ([], []) }
    func createGroup(identity: IsolatedRuntimeIdentity) throws {
        groupCreates += 1
        groupRecord = .init(
            name: IsolatedRuntimePolicy.accountName, gid: identity.serviceGID, guid: identity.groupGUID,
            comment: identity.accountComment)
    }
    func createUser(identity: IsolatedRuntimeIdentity) throws {
        if failUserCreation { throw CocoaError(.fileWriteNoPermission) }
        userCreates += 1
        userRecord = .init(
            name: IsolatedRuntimePolicy.accountName, uid: identity.serviceUID, gid: identity.serviceGID,
            guid: identity.accountGUID,
            home: IsolatedRuntimePolicy.home.path, shell: "/usr/bin/false", comment: identity.accountComment,
            hidden: true, loginDisabled: true)
    }
}
extension ServiceAccountPlanTests {
    func testInterruptedCreationResumesSameIdentityAndNeverRepeatsGroupCreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = DirectoryFixture()
        directory.failUserCreation = true
        let path = root.appendingPathComponent("account-plan.json")
        let provisioner = ServiceAccountProvisioner(directory: directory, journal: path)
        XCTAssertThrowsError(try provisioner.prepare(ownerUID: 501))
        let planned = try JSONDecoder().decode(IsolatedRuntimeIdentity.self, from: Data(contentsOf: path))
        XCTAssertEqual(directory.groupCreates, 1)
        XCTAssertEqual(directory.userCreates, 0)
        directory.failUserCreation = false
        let recovered = try ServiceAccountProvisioner(directory: directory, journal: path).prepare(ownerUID: 501)
        XCTAssertEqual(recovered, planned)
        XCTAssertEqual(directory.groupCreates, 1)
        XCTAssertEqual(directory.userCreates, 1)
        _ = try provisioner.prepare(ownerUID: 501)
        XCTAssertEqual(directory.userCreates, 1)
        XCTAssertThrowsError(try provisioner.prepare(ownerUID: 502))
    }
    func testExistingForeignNameIsLeftUntouchedBeforeAnyJournalOrMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = DirectoryFixture()
        directory.groupRecord = .init(
            name: IsolatedRuntimePolicy.accountName, gid: 400, guid: UUID(), comment: "unrelated")
        let path = root.appendingPathComponent("account-plan.json")
        XCTAssertThrowsError(try ServiceAccountProvisioner(directory: directory, journal: path).prepare(ownerUID: 501))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(directory.groupCreates + directory.userCreates, 0)
    }
}
