import Foundation

enum CICacheMeasurementIdentity {
    static func valid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func namedVolume(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 512 && !value.contains(where: { "/\\\n\r\0".contains($0) })
    }
}

/// A late background observation. A queued job report is not this result.
struct CICacheSaveReport: Decodable, Sendable, Identifiable {
    let runnerId: String?
    let projectId: String?
    let runId: String?
    let attemptId: String
    let nodeId: String
    let observedAt: String?
    let save: Save

    struct Key: Hashable, Sendable {
        let runner: String?
        let attempt: String
        let cache: String
        let container: String
        let finished: String
    }
    var id: Key {
        Key(
            runner: runnerId, attempt: attemptId, cache: save.cacheId,
            container: save.containerId, finished: save.finishedAt)
    }

    struct Save: Decodable, Sendable {
        let cacheId: String
        let volumeName: String?
        let containerId: String
        let outcome: String
        let durationMs: UInt64?
        private let allocatedBytes: UInt64?
        let finishedAt: String
        var finishTime: Date? { CICacheTelemetry.date(finishedAt) }
        var acknowledgedAllocation: UInt64? { outcome == "committed" ? allocatedBytes : nil }
        var outcomeLabel: String {
            switch outcome {
            case "committed": "Save acknowledged"
            case "superseded": "Save superseded"
            case "refused": "Save refused"
            case "missing": "Clone missing"
            case "unheld": "Golden no longer held; no commit attempted"
            default: "Save outcome unknown; may have landed"
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case runnerId, projectId, runId, attemptId, nodeId, observedAt, save
    }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        runnerId = try fields.decodeIfPresent(String.self, forKey: .runnerId)
        projectId = try fields.decodeIfPresent(String.self, forKey: .projectId)
        runId = try fields.decodeIfPresent(String.self, forKey: .runId)
        observedAt = try fields.decodeIfPresent(String.self, forKey: .observedAt)
        attemptId = try fields.decode(String.self, forKey: .attemptId)
        nodeId = try fields.decode(String.self, forKey: .nodeId)
        save = try fields.decode(Save.self, forKey: .save)
        guard
            [
                runnerId ?? "", projectId ?? "", runId ?? "", observedAt ?? "", attemptId, nodeId,
                save.volumeName ?? "", save.containerId, save.finishedAt,
            ].allSatisfy({ $0.count <= 512 }),
            CICacheMeasurementIdentity.valid(save.cacheId),
            save.volumeName.map(CICacheMeasurementIdentity.namedVolume) != false,
            ["committed", "superseded", "refused", "missing", "unknown", "unheld"].contains(save.outcome)
        else { throw CICacheReadError.invalidCounters }
    }
}

/// One malformed late event does not hide independent valid proxy observations.
struct CICacheOptionalSave: Decodable {
    let value: CICacheSaveReport?
    init(from decoder: Decoder) throws { value = try? CICacheSaveReport(from: decoder) }
}

/// Recomputed from this read's volatile windows. No durable history is claimed.
struct CICacheRecentActivity: Sendable, Identifiable {
    struct Key: Hashable, Sendable {
        let runnerID: String
        let cacheID: String
    }
    let id: Key
    var volumeNames = Set<String>()
    var attemptIDs = Set<String>()
    var existing = 0
    var seeded = 0
    var cold = 0
    var resolutions: [UInt64] = []
    var saves: [CICacheSaveReport] = []
    var lastReport: Date?

    var resolutionCost: UInt64? { Self.sum(resolutions) }
    var saveCost: UInt64? { Self.sum(saves.compactMap(\.save.durationMs)) }
    var lastSave: Date? { saves.compactMap(\.save.finishTime).max() }
    private static func sum(_ values: [UInt64]) -> UInt64? {
        guard !values.isEmpty else { return nil }
        var result: UInt64 = 0
        for value in values {
            let next = result.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            result = next.partialValue
        }
        return result
    }

    static func observations(_ telemetry: CICacheTelemetry, selection: CICacheSelection) -> [Self] {
        var groups: [Key: Self] = [:]
        for attempt in telemetry.jobReports(for: selection) {
            guard let runner = attempt.runnerId, !runner.isEmpty else { continue }
            for store in attempt.report.stores {
                guard let cache = store.cacheId else { continue }
                let key = Key(runnerID: runner, cacheID: cache)
                var group = groups[key] ?? Self(id: key)
                if let volume = store.volumeName { group.volumeNames.insert(volume) }
                // A repeated mount in one job is one observation for this identity.
                if group.attemptIDs.insert(attempt.attemptId).inserted {
                    switch store.golden {
                    case "hit": group.existing += 1
                    case "seeded": group.seeded += 1
                    case "cold": group.cold += 1
                    default: break
                    }
                    if let cost = store.resolveMs { group.resolutions.append(cost) }
                }
                if let time = attempt.observationTime, time <= telemetry.receivedAt.addingTimeInterval(5) {
                    group.lastReport = max(group.lastReport ?? time, time)
                }
                groups[key] = group
            }
        }
        for event in telemetry.saveReports(for: selection) {
            guard let runner = event.runnerId, !runner.isEmpty else { continue }
            let key = Key(runnerID: runner, cacheID: event.save.cacheId)
            var group = groups[key] ?? Self(id: key)
            if let volume = event.save.volumeName { group.volumeNames.insert(volume) }
            group.saves.append(event)
            groups[key] = group
        }
        return groups.values.sorted {
            let left = max($0.lastReport ?? .distantPast, $0.lastSave ?? .distantPast)
            let right = max($1.lastReport ?? .distantPast, $1.lastSave ?? .distantPast)
            if left != right { return left > right }
            if $0.id.runnerID != $1.id.runnerID { return $0.id.runnerID < $1.id.runnerID }
            return $0.id.cacheID < $1.id.cacheID
        }
    }
}

enum CICacheDurationFormat {
    static func string(_ value: UInt64?) -> String {
        value.map { "\($0.formatted()) ms" } ?? "Unknown"
    }
}
