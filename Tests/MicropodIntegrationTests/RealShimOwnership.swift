import Foundation
import MicropodCore

struct RealShimResourceSnapshot {
    let id: String
    let labels: [String: String]
}

struct RealShimOwnershipError: Error, CustomStringConvertible {
    let description: String
}

/// A successful create receipt plus a per-invocation label, never a name prefix,
/// grants cleanup eligibility. The live resource is rechecked before deletion.
@MainActor
final class RealShimOwnership {
    static let labelKey = "dev.micropod.tests.realshim-owner"
    let token = UUID().uuidString
    private(set) var isActive = false
    private(set) var createdIDs: Set<String> = []

    var labels: [String: String] { [Self.labelKey: token] }

    func activate() { isActive = true }

    func recordCreation(status: Int, requestedID: String, returnedID: String) throws {
        guard isActive, status == 201, !requestedID.isEmpty, requestedID == returnedID else {
            throw RealShimOwnershipError(description: "Unverified create receipt for \(requestedID), status \(status)")
        }
        createdIDs.insert(returnedID)
    }

    func forgetRemoved(_ id: String) { createdIDs.remove(id) }

    func owns(_ snapshot: RealShimResourceSnapshot) -> Bool {
        isActive && createdIDs.contains(snapshot.id) && snapshot.labels[Self.labelKey] == token
    }

    static func decodeSnapshot(_ data: Data, expectedID: String) throws -> RealShimResourceSnapshot? {
        let entries = try MicropodJSON.decodeArray(ContainerListEntry.self, from: data, context: "owned test container")
        if entries.isEmpty { return nil }
        guard entries.count == 1, let entry = entries.first, entry.id == expectedID else {
            throw RealShimOwnershipError(description: "Inspection returned an unexpected identity for \(expectedID)")
        }
        return RealShimResourceSnapshot(id: entry.id, labels: entry.configuration.labels ?? [:])
    }

    func cleanup(
        inspect: (String) async throws -> RealShimResourceSnapshot?,
        delete: (String) async throws -> Void
    ) async -> [String] {
        guard isActive else { return [] }
        var failures: [String] = []
        for id in createdIDs.sorted() {
            do {
                guard let snapshot = try await inspect(id) else {
                    createdIDs.remove(id)
                    continue
                }
                guard snapshot.id == id, owns(snapshot) else {
                    failures.append("Preserved \(id): ownership not verified")
                    continue
                }
                try await delete(id)
                createdIDs.remove(id)
            } catch {
                failures.append("Preserved \(id): cleanup failed: \(error)")
            }
        }
        return failures
    }
}
