import Foundation
import XCTest

@MainActor
final class RealShimOwnershipTests: XCTestCase {
    func testSkippedSetupMakesNoRuntimeCalls() async {
        let owner = RealShimOwnership()
        var calls: [String] = []
        let failures = await owner.cleanup(
            inspect: { id in
                calls.append("inspect:\(id)")
                return nil
            },
            delete: { id in calls.append("delete:\(id)") })
        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(calls.isEmpty)
    }

    func testFailedAndUnverifiedCreatesNeverGrantOwnership() async {
        let owner = RealShimOwnership()
        XCTAssertThrowsError(try owner.recordCreation(status: 201, requestedID: "new", returnedID: "new"))
        owner.activate()
        for status in [200, 409, 500] {
            XCTAssertThrowsError(
                try owner.recordCreation(status: status, requestedID: "existing", returnedID: "existing"))
        }
        XCTAssertThrowsError(try owner.recordCreation(status: 201, requestedID: "new", returnedID: "other"))
        XCTAssertThrowsError(try owner.recordCreation(status: 201, requestedID: "", returnedID: ""))
        var calls = 0
        _ = await owner.cleanup(
            inspect: { _ in
                calls += 1
                return nil
            }, delete: { _ in calls += 1 })
        XCTAssertTrue(owner.createdIDs.isEmpty)
        XCTAssertEqual(calls, 0)
    }

    func testOnlyRecordedAndCurrentlyLabelledResourceIsDeleted() async throws {
        let owner = RealShimOwnership()
        owner.activate()
        try owner.recordCreation(status: 201, requestedID: "realshim-current", returnedID: "realshim-current")
        let available = [
            "realshim-current": RealShimResourceSnapshot(id: "realshim-current", labels: owner.labels),
            "realshim-old": RealShimResourceSnapshot(id: "realshim-old", labels: owner.labels),
        ]
        var inspected: [String] = []
        var deleted: [String] = []
        let failures = await owner.cleanup(
            inspect: { id in
                inspected.append(id)
                return available[id]
            },
            delete: { deleted.append($0) })
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(inspected, ["realshim-current"])
        XCTAssertEqual(deleted, ["realshim-current"])
        XCTAssertTrue(owner.createdIDs.isEmpty)
        _ = await owner.cleanup(
            inspect: { _ in
                XCTFail("Already cleaned")
                return nil
            }, delete: { _ in XCTFail("Already cleaned") })
    }

    func testMismatchedIdentityMissingLabelAndForeignLabelArePreserved() async throws {
        for kind in ["identity", "missing label", "foreign label"] {
            let owner = RealShimOwnership()
            owner.activate()
            try owner.recordCreation(status: 201, requestedID: "owned", returnedID: "owned")
            let snapshot = RealShimResourceSnapshot(
                id: kind == "identity" ? "other" : "owned",
                labels: kind == "missing label"
                    ? [:] : kind == "foreign label" ? RealShimOwnership().labels : owner.labels)
            var deletes = 0
            let failures = await owner.cleanup(inspect: { _ in snapshot }, delete: { _ in deletes += 1 })
            XCTAssertEqual(deletes, 0, kind)
            XCTAssertEqual(failures.count, 1, kind)
            XCTAssertEqual(owner.createdIDs, ["owned"], kind)
        }
    }

    func testInspectionFailurePreservesResourceAndReceipt() async throws {
        let owner = RealShimOwnership()
        owner.activate()
        try owner.recordCreation(status: 201, requestedID: "owned", returnedID: "owned")
        var deletes = 0
        let failures = await owner.cleanup(
            inspect: { _ in throw RealShimOwnershipError(description: "runtime unavailable") },
            delete: { _ in deletes += 1 })
        XCTAssertEqual(deletes, 0)
        XCTAssertTrue(failures.joined().contains("runtime unavailable"))
        XCTAssertEqual(owner.createdIDs, ["owned"])
    }

    func testDeleteFailureIsReportedAndReceiptRetained() async throws {
        let owner = RealShimOwnership()
        owner.activate()
        try owner.recordCreation(status: 201, requestedID: "owned", returnedID: "owned")
        let failures = await owner.cleanup(
            inspect: { id in RealShimResourceSnapshot(id: id, labels: owner.labels) },
            delete: { _ in throw RealShimOwnershipError(description: "delete failed") })
        XCTAssertTrue(failures.joined().contains("delete failed"))
        XCTAssertEqual(owner.createdIDs, ["owned"])
    }

    func testAlreadyReapedResourceNeedsNoDelete() async throws {
        let owner = RealShimOwnership()
        owner.activate()
        try owner.recordCreation(status: 201, requestedID: "gone", returnedID: "gone")
        let failures = await owner.cleanup(inspect: { _ in nil }, delete: { _ in XCTFail("Already gone") })
        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(owner.createdIDs.isEmpty)
    }

    func testExplicitRemovalForgetsOnlyThatResource() async throws {
        let owner = RealShimOwnership()
        owner.activate()
        for id in ["removed", "survivor"] { try owner.recordCreation(status: 201, requestedID: id, returnedID: id) }
        owner.forgetRemoved("removed")
        var inspected: [String] = []
        let failures = await owner.cleanup(
            inspect: { id in
                inspected.append(id)
                return RealShimResourceSnapshot(id: id, labels: owner.labels)
            },
            delete: { _ in })
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(inspected, ["survivor"])
    }

    func testLiveAdapterDecodesMatchingIdentityAndLabels() throws {
        let data = Data(
            #"[{"id":"owned","configuration":{"labels":{"owner":"token"}},"status":{"state":"running"}}]"#.utf8)
        let snapshot = try XCTUnwrap(RealShimOwnership.decodeSnapshot(data, expectedID: "owned"))
        XCTAssertEqual(snapshot.id, "owned")
        XCTAssertEqual(snapshot.labels, ["owner": "token"])
    }

    func testLiveAdapterAcceptsOnlyVerifiedEmptyResultAsAbsent() throws {
        XCTAssertNil(try RealShimOwnership.decodeSnapshot(Data("[]".utf8), expectedID: "owned"))
    }

    func testLiveAdapterRejectsWrongOrAmbiguousIdentity() throws {
        let wrong = Data(#"[{"id":"other","configuration":{},"status":{}}]"#.utf8)
        XCTAssertThrowsError(try RealShimOwnership.decodeSnapshot(wrong, expectedID: "owned"))
        let multiple = Data(
            #"[{"id":"owned","configuration":{},"status":{}},{"id":"other","configuration":{},"status":{}}]"#.utf8)
        XCTAssertThrowsError(try RealShimOwnership.decodeSnapshot(multiple, expectedID: "owned"))
    }

    func testLiveAdapterRejectsMalformedInspection() {
        for value in ["{", "null", #"[{"unexpected":true}]"#] {
            XCTAssertThrowsError(try RealShimOwnership.decodeSnapshot(Data(value.utf8), expectedID: "owned"))
        }
    }

}
