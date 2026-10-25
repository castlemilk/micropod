import Foundation
import MicropodCore

/// Apple uses `stopped` both before the first start and after exit. Preserve
/// running/terminal observations except where this process owns unfinished
/// creation/start work, or knows it has never started the container.
enum NativePendingState {
    /// A complete read fenced against admission/completion. Absence during
    /// owned creation/start is pending, not proof that output has finished.
    static func observe(
        id: String, claims: ContainerLifecycleClaims = .shared,
        unstarted: @Sendable (String) async -> Bool = { await UnstartedCreates.shared.contains($0) },
        read: @Sendable () async throws -> String?
    ) async throws -> String? {
        for _ in 0..<3 {
            let revision = await claims.revision()
            let raw = try await read()
            let kind = await claims.kind(of: id)
            let neverStarted = await unstarted(id)
            guard await claims.revision() == revision else { continue }
            if let raw {
                return state(raw, starting: kind == .starting, creating: kind == .creating, unstarted: neverStarted)
            }
            if kind == .starting { return "starting" }
            if kind == .creating { return "created" }
            return nil
        }
        throw MicropodError.message("unavailable: container lifecycle changed during observation; retry")
    }

    static func state(_ raw: String, starting: Bool, creating: Bool = false, unstarted: Bool) -> String {
        guard raw == "stopped" else { return raw }
        if starting { return "starting" }
        return creating || unstarted ? "created" : raw
    }

    /// `inspect` carries fields the curated list model omits. Change only
    /// status.state so Get/List and the shared inspect-based Wait agree.
    static func normalizeInspect(
        _ data: Data,
        state: @Sendable (String, String) async -> String
    ) async throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        let wasArray = object is [Any]
        let rows: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rows = array
        } else if let row = object as? [String: Any] {
            rows = [row]
        } else {
            return data
        }
        var result: [[String: Any]] = []
        for var row in rows {
            if let id = row["id"] as? String, var status = row["status"] as? [String: Any],
                let raw = status["state"] as? String
            {
                status["state"] = await state(id, raw)
                row["status"] = status
            }
            result.append(row)
        }
        return try JSONSerialization.data(withJSONObject: wasArray ? result : result[0])
    }
}
