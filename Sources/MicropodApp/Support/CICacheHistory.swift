import Foundation

/// Curated v1 facts only. Unknown fields (including environment) are never retained.
struct CICacheHistoryEvent: Codable, Sendable {
    let sequence: UInt64
    let sessionId: String
    let recordedAt: String
    let kind: String
    let attempt: CICacheAttemptReport?
    let save: CICacheSaveReport?

    var isValid: Bool {
        guard sequence > 0, UUID(uuidString: sessionId) != nil,
            recordedAt.count <= 512, CICacheTelemetry.date(recordedAt) != nil
        else { return false }
        switch kind {
        case "session-start": return attempt == nil && save == nil
        case "attempt":
            guard let attempt, save == nil else { return false }
            return [
                attempt.runnerId ?? "", attempt.projectId ?? "", attempt.runId ?? "",
                attempt.attemptId, attempt.nodeId, attempt.observedAt ?? "",
            ]
            .allSatisfy { $0.count <= 512 }
        case "save": return save != nil && attempt == nil
        default: return false
        }
    }
}

struct CICacheHistoryPage: Codable, Sendable {
    static let version = "cache-history-v1"
    static let byteLimit = 131_072
    let schemaVersion: String
    let historyId: String
    let createdAt: String
    let lastSequence: UInt64
    let sessions: UInt64
    let evictedRecords: UInt64
    let lostRecords: UInt64
    let retainedBytes: UInt64
    let retainedRecords: UInt64
    let status: String
    let complete: Bool
    let leaseCoverage: String
    let coverageReasons: [String]
    let sessionId: String?
    let pendingRecords: UInt64
    let unpersistedLoss: UInt64
    let oldestSequence: UInt64
    let nextAfter: UInt64
    let truncatedBefore: Bool
    var events: [CICacheHistoryEvent]?

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= byteLimit else { throw CICacheReadError.invalidCounters }
        let page = try JSONDecoder().decode(Self.self, from: data)
        guard page.schemaVersion == version, !page.complete, page.leaseCoverage == "unavailable",
            page.status.count <= 64, page.historyId.count <= 512, page.createdAt.count <= 512,
            page.coverageReasons.count <= 32, page.coverageReasons.allSatisfy({ $0.count <= 128 }),
            page.retainedRecords <= 2048, page.retainedBytes <= 4_194_304,
            (page.events?.count ?? 0) <= 128, (page.events ?? []).allSatisfy(\.isValid)
        else { throw CICacheReadError.invalidCounters }
        if page.status == "available" {
            guard UUID(uuidString: page.historyId) != nil,
                page.sessionId.flatMap(UUID.init(uuidString:)) != nil,
                page.oldestSequence <= page.lastSequence,
                page.createdAt.isEmpty == false, CICacheTelemetry.date(page.createdAt) != nil
            else { throw CICacheReadError.invalidCounters }
        }
        return page
    }
}

protocol CICacheHistoryPageReading: Sendable {
    func read(after: UInt64) async throws -> CICacheHistoryPage
}

struct LocalCICacheHistoryPageReader: CICacheHistoryPageReading {
    static let endpoint = URL(string: "http://127.0.0.1:5555/cache/history")!
    func read(after: UInt64) async throws -> CICacheHistoryPage {
        var url = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "after", value: String(after)), URLQueryItem(name: "limit", value: "128")]
        let data = try await LocalCICacheTelemetryReader.readData(
            from: url.url!, byteLimit: CICacheHistoryPage.byteLimit)
        return try CICacheHistoryPage.decode(data)
    }
}

protocol CICacheHistoryPersisting: Sendable {
    func load() async throws -> Data?
    func save(_ data: Data) async throws
}

/// A small observer file, separate from the producer DB and cache volumes.
actor LocalCICacheHistoryPersistence: CICacheHistoryPersisting {
    static let byteLimit = 4_194_304
    private let url: URL
    init(
        url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Micropod/cache-observations-v1.json")
    ) { self.url = url }
    func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try url.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false
        else {
            throw CICacheReadError.unavailable
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
        guard values.isSymbolicLink == false, values.isRegularFile == true,
            let size = values.fileSize, size <= Self.byteLimit
        else { throw CICacheReadError.unavailable }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= Self.byteLimit else { throw CICacheReadError.unavailable }
        return data
    }
    func save(_ data: Data) throws {
        guard data.count <= Self.byteLimit else { throw CICacheReadError.unavailable }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard try parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else {
            throw CICacheReadError.unavailable
        }
        if FileManager.default.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]).isSymbolicLink == false,
                try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { throw CICacheReadError.unavailable }
        }
        try data.write(to: url, options: .atomic)
    }
}

struct CICacheHistoryState: Codable, Sendable {
    var observerVersion = 1
    var source = LocalCICacheHistoryPageReader.endpoint.absoluteString
    var historyId: String?
    var sessionId: String?
    var after: UInt64 = 0
    var events: [CICacheHistoryEvent] = []
    var gaps: [String] = []
    var summary: CICacheHistoryPage?
    var sampledAt: Date?
    mutating func gap(_ reason: String) {
        if !gaps.contains(reason), gaps.count < 32 { gaps.append(reason) }
    }
}

struct CICacheHistorySnapshot: Sendable {
    let state: CICacheHistoryState
    let error: String?
    let persisted: Bool
    let traversalLimited: Bool
    var telemetry: CICacheTelemetry {
        CICacheTelemetry(
            receivedAt: state.sampledAt ?? .distantPast, counters: [],
            attempts: state.events.compactMap(\.attempt), saves: state.events.compactMap(\.save),
            saveFeedAvailable: true)
    }
    /// v1 cannot establish complete access history or authoritative protection.
    var retentionBlockers: [String] {
        ["Cache access history is incomplete.", "Authoritative lease coverage is unavailable."]
    }
}

protocol CICacheHistoryReading: Sendable {
    func read() async -> CICacheHistorySnapshot
}

actor CICacheHistoryConsumer: CICacheHistoryReading {
    private let reader: any CICacheHistoryPageReading
    private let persistence: any CICacheHistoryPersisting
    private var state = CICacheHistoryState()
    private var loaded = false
    private var refreshing = false
    private var persistenceAllowed = true
    private var persisted = false
    init(
        reader: any CICacheHistoryPageReading = LocalCICacheHistoryPageReader(),
        persistence: any CICacheHistoryPersisting = LocalCICacheHistoryPersistence()
    ) {
        self.reader = reader
        self.persistence = persistence
    }

    func read() async -> CICacheHistorySnapshot {
        guard !refreshing else { return snapshot(error: "History refresh is already in progress.") }
        refreshing = true
        defer { refreshing = false }
        if !loaded {
            loaded = true
            do {
                if let data = try await persistence.load() {
                    guard data.count <= LocalCICacheHistoryPersistence.byteLimit else {
                        throw CICacheReadError.unavailable
                    }
                    let cached = try JSONDecoder().decode(CICacheHistoryState.self, from: data)
                    guard let summary = cached.summary else { throw CICacheReadError.unavailable }
                    let validatedSummary = try CICacheHistoryPage.decode(JSONEncoder().encode(summary))
                    let sequences = cached.events.map(\.sequence)
                    guard cached.observerVersion == 1, cached.source == state.source, cached.events.count <= 2048,
                        cached.events.allSatisfy(\.isValid), cached.gaps.count <= 32,
                        cached.gaps.allSatisfy({ $0.count <= 128 }),
                        cached.historyId.flatMap(UUID.init(uuidString:)) != nil,
                        cached.events.allSatisfy({ $0.sequence <= cached.after }),
                        cached.summary?.schemaVersion == CICacheHistoryPage.version,
                        cached.summary?.complete == false, cached.summary?.leaseCoverage == "unavailable",
                        cached.summary?.historyId == cached.historyId,
                        cached.after <= validatedSummary.lastSequence, validatedSummary.status == "available",
                        cached.sessionId == validatedSummary.sessionId,
                        (cached.events.last?.sequence ?? 0) == cached.after,
                        zip(sequences, sequences.dropFirst()).allSatisfy({ $0.0 < $0.1 })
                    else { throw CICacheReadError.unavailable }
                    state = cached
                    persisted = true
                }
            } catch {
                persistenceAllowed = false
                state.gap("consumer-state-unavailable")
            }
        }
        var traversal = state
        var upper: UInt64?
        var expectedHistory: String?
        for pageIndex in 0..<4 {
            do {
                try Task.checkCancellation()
                let requested = traversal.after
                let page = try await reader.read(after: requested)
                try Task.checkCancellation()
                guard page.schemaVersion == CICacheHistoryPage.version, !page.complete,
                    page.leaseCoverage == "unavailable"
                else { throw CICacheReadError.invalidCounters }
                guard page.status == "available" else {
                    state.gap("producer-\(page.status)")
                    return snapshot(
                        error: "Producer history unavailable (\(page.status)); retained observations are earlier reads."
                    )
                }
                if let expectedHistory, expectedHistory != page.historyId {
                    state.gap("history-changed-during-read")
                    return snapshot(
                        error: "Producer identity changed during history traversal; retry from its new identity.")
                }
                let records = page.events ?? []
                var previous = requested
                for event in records {
                    guard event.isValid, event.sequence > previous, event.sequence <= page.lastSequence else {
                        throw CICacheReadError.invalidCounters
                    }
                    previous = event.sequence
                }
                guard page.nextAfter == (records.last?.sequence ?? requested) else {
                    throw CICacheReadError.invalidCounters
                }
                if pageIndex == 0, traversal.historyId != page.historyId || traversal.after > page.lastSequence {
                    let changed = traversal.historyId != nil
                    traversal = CICacheHistoryState()
                    traversal.gaps = state.gaps.filter { $0.hasPrefix("consumer-") }
                    traversal.historyId = page.historyId
                    if changed { traversal.gap("producer-history-reset") }
                    if requested > page.lastSequence { traversal.gap("cursor-ahead-of-producer") }
                    upper = page.lastSequence
                    expectedHistory = page.historyId
                    if requested > 0 { continue }  // Stage reset until a successful read from zero.
                }
                expectedHistory = page.historyId
                if let session = traversal.sessionId, session != page.sessionId { traversal.gap("producer-restart") }
                traversal.sessionId = page.sessionId
                if upper == nil { upper = page.lastSequence }
                guard page.lastSequence >= upper! else { throw CICacheReadError.invalidCounters }
                if page.truncatedBefore || (page.oldestSequence > 0 && traversal.after < page.oldestSequence - 1) {
                    traversal.gap("producer-retention-truncated")
                }
                let consumed = records.filter { $0.sequence <= upper! }
                if consumed.isEmpty, traversal.after < upper! {
                    state.gap("page-ended-before-snapshot")
                    return snapshot(error: "History page ended before the captured sequence; coverage has a gap.")
                }
                var nextState = traversal
                for event in consumed {
                    let next = nextState.after.addingReportingOverflow(1)
                    if next.overflow || event.sequence != next.partialValue { nextState.gap("sequence-gap") }
                    if event.attempt?.report.invalidProxy == true || event.attempt?.report.invalidStores == true {
                        nextState.gap("invalid-measurements")
                    }
                    nextState.events.append(event)
                    nextState.after = event.sequence
                }
                if page.sessions > 1 { nextState.gap("producer-restart-gap") }
                if page.lostRecords > 0 || page.unpersistedLoss > 0 { nextState.gap("producer-observations-lost") }
                var summary = page
                summary.events = nil
                nextState.summary = summary
                nextState.sampledAt = Date()
                while nextState.events.count > 2048 {
                    nextState.events.removeFirst()
                    nextState.gap("consumer-window-truncated")
                }
                var encoded = try JSONEncoder().encode(nextState)
                while encoded.count > LocalCICacheHistoryPersistence.byteLimit, !nextState.events.isEmpty {
                    nextState.events.removeFirst()
                    nextState.gap("consumer-window-truncated")
                    encoded = try JSONEncoder().encode(nextState)
                }
                state = nextState  // Cursor and curated facts advance together only after validating the whole page.
                traversal = nextState
                persisted = false
                if persistenceAllowed {
                    do {
                        try await persistence.save(encoded)
                        persisted = true
                    } catch { state.gap("consumer-persistence-unavailable") }
                }
                if state.after >= upper! { return snapshot() }
            } catch is CancellationError {
                return snapshot(error: "History read cancelled; coverage remains incomplete.")
            } catch {
                state.gap("history-read-unavailable")
                return snapshot(
                    error: "History schema, page or read unavailable; retained observations are earlier reads.")
            }
        }
        return snapshot(limited: true)
    }

    private func snapshot(error: String? = nil, limited: Bool = false) -> CICacheHistorySnapshot {
        CICacheHistorySnapshot(state: state, error: error, persisted: persisted, traversalLimited: limited)
    }
}
