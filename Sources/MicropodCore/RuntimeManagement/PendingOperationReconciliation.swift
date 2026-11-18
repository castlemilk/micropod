import Darwin
import Foundation

/// The durable receipt for one admitted runtime operation,
/// `admission/pending/<operation>.json`. A claim writes it before the
/// operation reaches the runtime; a completed or definitively failed
/// operation removes it. One that is left blocks runtime maintenance until
/// reconciliation proves it dead (``PendingOperationReconciliation``).
public struct PendingRuntimeOperation: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// The caller stopped waiting without an authoritative answer.
        case uncertain
        /// The runtime answered with an error, or the call never reached it.
        case failed
    }

    public let operation: UUID
    public let route: String
    public let pid: Int32
    // Receipts written by older builds carry only the three fields above.
    /// The claiming process (pid, start time, boot session): pid reuse
    /// cannot make a dead owner look alive, nor a live one dead.
    public var owner: RuntimeProcessBirth?
    public var createdAt: Date?
    /// The container the operation acts on, when it names one.
    public var container: String?
    public var outcome: Outcome?
    /// When the caller stopped waiting (set with `outcome`).
    public var endedAt: Date?

    public init(
        operation: UUID, route: String, pid: Int32, owner: RuntimeProcessBirth? = nil, createdAt: Date? = nil,
        container: String? = nil, outcome: Outcome? = nil, endedAt: Date? = nil
    ) {
        self.operation = operation
        self.route = route
        self.pid = pid
        self.owner = owner
        self.createdAt = createdAt
        self.container = container
        self.outcome = outcome
        self.endedAt = endedAt
    }

    /// This process's birth, read once.
    static let currentOwner: RuntimeProcessBirth? = try? RuntimeProcessBirth.read(getpid())

    /// Whether the operation's own work runs inside the claiming process
    /// and holds its claim until that work ends. `native.create` and
    /// `native.start` (every build that writes them) keep the claim alive
    /// across the whole create or start, dispatched worker included, and
    /// every Apple runtime call they make takes its own XPC receipt, held
    /// until the apiserver replies. So once the claim is released, nothing
    /// of theirs is still running here, and anything still queued in the
    /// apiserver has a receipt of its own.
    ///
    /// Every other route can leave work behind its claim: an XPC or
    /// `container` CLI call runs in Apple's apiserver or a child process, a
    /// terminal in its `container exec`, and a `managed-api:` request can
    /// start any of them, so a crash of its process can strand that work.
    public var runsInOwner: Bool {
        route == "native.create" || route == "native.start"
    }
}

/// A container listing taken just before maintenance closes admission.
public struct StaleOperationEvidence: Sendable, Equatable {
    /// When the listing was requested. The listing itself is no older.
    public let observedAt: Date
    /// Every container id the runtime listed.
    public let liveContainers: Set<String>

    public init(observedAt: Date, liveContainers: Set<String>) {
        self.observedAt = observedAt
        self.liveContainers = liveContainers
    }
}

/// How the process that claimed an operation stands now.
public enum PendingOwnerState: Equatable, Sendable {
    case running
    case exited
    /// The receipt was written before the current boot.
    case earlierBoot
    /// The process table could not be read.
    case unknown
}

/// Why a receipt was proved dead.
public struct PendingRetirement: Codable, Equatable, Sendable {
    public enum Rule: String, Codable, Sendable {
        case failed
        case earlierBoot = "earlier-boot"
        case claimReleased = "claim-released"
        case ownerExited = "owner-exited"
        case containerAbsent = "container-absent"
    }
    public let rule: Rule
    public let reason: String
}

public enum PendingOperationVerdict: Equatable, Sendable {
    /// Provably dead, with the rule that proved it.
    case dead(PendingRetirement)
    /// Still blocks maintenance, with why it could not be proved dead.
    case blocking(String)
}

/// Decides which leftover receipts can be proved dead. It runs only while
/// the admission gate is held exclusively (``RuntimeAdmission/begin``), so
/// no claim is live in any process: every receipt it sees belongs to an
/// operation whose caller has already returned, or whose process exited.
///
/// A receipt is dead when one of these holds:
///  1. **Failed** — its owner recorded a definitive failure. (Owners delete
///     those receipts; one left behind by a crash between write and delete
///     is retired here.)
///  2. **Earlier boot** — it was written before this boot. Apple's runtime
///     and every process that could act on it have restarted since.
///  3. **Claim released** — the route's work runs inside the claiming
///     process and holds its claim until it ends
///     (``PendingRuntimeOperation/runsInOwner``: `native.create`,
///     `native.start`). Holding the gate exclusively proves that claim was
///     released, so its work is over, whether or not its owner still runs;
///     the runtime calls it made are judged by their own receipts.
///  4. **Owner exited** — the claiming process no longer exists and the
///     receipt is older than ``staleOperationAge``, so a runtime call it
///     left queued in Apple's apiserver has had that long to finish.
///  5. **Container absent** — the receipt names a container, was at least
///     ``staleOperationAge`` old when a fresh listing was requested, and
///     that listing does not contain the container. If the operation is in
///     fact still queued in the apiserver (a create in a backlog), the
///     maintenance that follows drops it: its caller has long since timed
///     out and must treat that attempt as failed or retryable. Retiring one
///     logs a warning naming the operation, the container and its age.
///
/// Anything else still blocks — the receipt of a runtime call whose owner
/// is running and that names no container listed as gone, an owner that
/// cannot be read, an unreadable or unrecognised entry. Retired receipts are moved to
/// `admission/reconciled/` with the rule that retired them, never deleted
/// unseen; the newest ``retainedReconciledReceipts`` are kept.
public enum PendingOperationReconciliation {
    /// How old an uncertain receipt must be before rules 4 and 5 may retire
    /// it: 10 minutes. The longest
    /// container operations a rig sends are bounded far below it — a create
    /// or start that misses a 30–60 s client deadline in a backlogged
    /// apiserver has been seen to land 60–70 s late, and a backlog that
    /// filled for 15 minutes drained in 13 once intake paused. Ten minutes
    /// is about eight times the worst late landing, short enough that a
    /// stuck receipt does not hold maintenance off for an operator's whole
    /// session.
    public static let staleOperationAge: TimeInterval = 10 * 60

    /// The oldest container listing rule 5 trusts.
    public static let evidenceMaximumAge: TimeInterval = 2 * 60

    /// Retired receipts kept under `admission/reconciled/` for audit.
    public static let retainedReconciledReceipts = 256

    public struct Blocking: Equatable, Sendable {
        public let route: String
        public let age: TimeInterval?
        public let why: String
    }

    /// The tolerance on the pid-reuse test for receipts that carry only a
    /// pid: a process that started more than this after the receipt was
    /// written cannot have written it. It absorbs small wall-clock steps.
    public static let pidReuseTolerance: TimeInterval = 2

    /// Judges one receipt. Only sound while the caller holds the admission
    /// gate exclusively (rule 3 depends on it).
    public static func verdict(
        _ record: PendingRuntimeOperation, writtenAt: Date, owner: PendingOwnerState,
        evidence: StaleOperationEvidence?, now: Date
    ) -> PendingOperationVerdict {
        func dead(_ rule: PendingRetirement.Rule, _ reason: String) -> PendingOperationVerdict {
            .dead(PendingRetirement(rule: rule, reason: reason))
        }
        if record.outcome == .failed { return dead(.failed, "the operation definitively failed") }
        if owner == .earlierBoot { return dead(.earlierBoot, "written before the current boot") }
        if record.runsInOwner {
            return dead(
                .claimReleased,
                "its claim was released, and its work runs in the claiming process for as long as the claim is held"
                    + (owner == .running ? " (owner still running)" : ""))
        }
        let age = now.timeIntervalSince(writtenAt)
        if owner == .exited, age >= staleOperationAge {
            return dead(.ownerExited, "its owner process exited and it is older than \(minutes(staleOperationAge))")
        }
        if let container = record.container, let evidence,
            now.timeIntervalSince(evidence.observedAt) <= evidenceMaximumAge,
            evidence.observedAt.timeIntervalSince(writtenAt) >= staleOperationAge,
            !evidence.liveContainers.contains(container)
        {
            return dead(
                .containerAbsent,
                "container \(container) was absent \(minutes(staleOperationAge)) after the operation began")
        }
        switch owner {
        case .running: return .blocking("owner running")
        case .exited: return .blocking("owner exited less than \(minutes(staleOperationAge)) ago")
        case .unknown: return .blocking("owner unconfirmed")
        case .earlierBoot: return .blocking("owner unconfirmed")
        }
    }

    /// How the claiming process stands, by its recorded birth, or — for a
    /// receipt from an older build — by its bare pid and the file's age.
    static func ownerState(
        _ record: PendingRuntimeOperation, writtenAt: Date, bootSession: String?, bootTime: Date?
    ) -> PendingOwnerState {
        if let owner = record.owner {
            if let bootSession, owner.bootSession != bootSession { return .earlierBoot }
            do { return try owner.hasExited() ? .exited : .running } catch { return .unknown }
        }
        if let bootTime, writtenAt < bootTime { return .earlierBoot }
        do {
            guard let current = try RuntimeProcessBirth.read(record.pid) else { return .exited }
            // A process that started after the receipt was written is a
            // reused pid: the writer has exited.
            let started = Date(
                timeIntervalSince1970: TimeInterval(current.seconds) + TimeInterval(current.microseconds) / 1_000_000)
            return started.timeIntervalSince(writtenAt) > pidReuseTolerance ? .exited : .running
        } catch {
            return .unknown
        }
    }

    /// One line for the maintenance refusal: what still blocks, grouped.
    static func describe(_ blocking: [Blocking]) -> String {
        struct Key: Hashable {
            let route: String
            let why: String
        }
        var groups: [Key: (count: Int, oldest: TimeInterval?)] = [:]
        var order: [Key] = []
        for item in blocking {
            let key = Key(route: item.route, why: item.why)
            if groups[key] == nil { order.append(key) }
            let previous = groups[key] ?? (0, nil)
            let oldest = [previous.oldest, item.age].compactMap { $0 }.max()
            groups[key] = (previous.count + 1, oldest)
        }
        var parts = order.prefix(4).map { key -> String in
            let group = groups[key]!
            let age = group.oldest.map { ", oldest \(duration($0))" } ?? ""
            return "\(group.count)× \(key.route): \(key.why)\(age)"
        }
        if order.count > 4 { parts.append("\(order.count - 4) more") }
        return parts.joined(separator: "; ")
    }

    private static func minutes(_ interval: TimeInterval) -> String { "\(Int(interval / 60)) min" }

    private static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 120 { return "\(seconds)s" }
        if seconds < 7200 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

/// A retired receipt as kept under `admission/reconciled/`.
struct RetiredPendingOperation: Codable {
    let file: String
    let record: PendingRuntimeOperation?
    /// The rule that proved it dead; nil for an incomplete receipt write.
    let rule: PendingRetirement.Rule?
    let reason: String
    let retiredAt: Date
}

extension RuntimeAdmission {
    /// Retires the provably dead receipts in `pending/` and returns those
    /// that still block. Call only while holding the gate exclusively.
    func reconcilePendingLocked(evidence: StaleOperationEvidence?, now: Date = Date()) throws
        -> [PendingOperationReconciliation.Blocking]
    {
        let pending = root.appendingPathComponent("pending")
        let names = try FileManager.default.contentsOfDirectory(atPath: pending.path)
        guard !names.isEmpty else { return [] }
        let bootSession = try? RuntimeProcessBirth.currentBootSession()
        let bootTime = RuntimeProcessBirth.bootTime()
        let pendingOwner = Self.ownerUID(of: pending)
        var blocking: [PendingOperationReconciliation.Blocking] = []
        for name in names.sorted() {
            let url = pending.appendingPathComponent(name)
            if name.hasPrefix(".intent-") {
                // RuntimeDurableFile.write's temporary. Every writer holds a
                // claim, and none is live, so its writer is gone; a receipt
                // that never got its name was never admitted.
                try retire(url, record: nil, retirement: nil, reason: "an incomplete receipt write", now: now)
                continue
            }
            guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil,
                let (record, writtenAt) = try? Self.readPending(url, ownerUID: pendingOwner)
            else {
                blocking.append(.init(route: "unrecognised entry", age: nil, why: "cannot be verified"))
                continue
            }
            let owner = PendingOperationReconciliation.ownerState(
                record, writtenAt: writtenAt, bootSession: bootSession, bootTime: bootTime)
            switch PendingOperationReconciliation.verdict(
                record, writtenAt: writtenAt, owner: owner, evidence: evidence, now: now)
            {
            case .dead(let retirement):
                try retire(url, record: record, retirement: retirement, reason: retirement.reason, now: now)
                if retirement.rule == .containerAbsent {
                    Self.warnDropped(record, age: now.timeIntervalSince(writtenAt))
                }
            case .blocking(let why):
                blocking.append(.init(route: record.route, age: now.timeIntervalSince(writtenAt), why: why))
            }
        }
        return blocking
    }

    private func retire(
        _ url: URL, record: PendingRuntimeOperation?, retirement: PendingRetirement?, reason: String, now: Date
    ) throws {
        let reconciled = root.appendingPathComponent("reconciled")
        let name =
            url.lastPathComponent.hasPrefix(".") ? "intent-" + UUID().uuidString + ".json" : url.lastPathComponent
        try RuntimeDurableFile.write(
            RetiredPendingOperation(
                file: url.lastPathComponent, record: record, rule: retirement?.rule, reason: reason, retiredAt: now),
            to: reconciled.appendingPathComponent(name))
        try RuntimeDurableFile.remove(url)
        let rule = retirement.map { " [\($0.rule.rawValue)]" } ?? ""
        FileHandle.standardError.write(
            Data(
                ("micropod: retired runtime receipt \(url.lastPathComponent) (\(record?.route ?? "partial"))\(rule): "
                    + "\(reason)\n").utf8))
        Self.pruneReconciled(reconciled, keeping: PendingOperationReconciliation.retainedReconciledReceipts)
    }

    /// A receipt retired because its container is absent may belong to an
    /// operation still queued in Apple's apiserver — a create in a backlog.
    /// The maintenance that follows drops it, so say so where an operator
    /// will look.
    static func warnDropped(_ record: PendingRuntimeOperation, age: TimeInterval) {
        FileHandle.standardError.write(
            Data(
                ("micropod: warning: retired \(record.route) operation \(record.operation.uuidString) for container "
                    + "\(record.container ?? "?") after \(Int(age / 60)) min: the runtime does not list the container. "
                    + "If the operation is still queued in Apple's apiserver, this maintenance drops it; its caller "
                    + "must treat that attempt as failed or retryable.\n").utf8))
    }

    private static func pruneReconciled(_ directory: URL, keeping limit: Int) {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
            entries.count > limit
        else { return }
        let dated = entries.map { url in
            (
                url,
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? .distantPast
            )
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(entries.count - limit) {
            try? fm.removeItem(at: url)
        }
    }

    private static func ownerUID(of directory: URL) -> uid_t {
        var info = stat()
        return lstat(directory.path, &info) == 0 ? info.st_uid : getuid()
    }

    /// A receipt and when it was written: its `createdAt`, or for an older
    /// build's receipt, the file's modification time (receipts are written
    /// once, at claim time).
    static func readPending(_ url: URL, ownerUID: uid_t) throws -> (PendingRuntimeOperation, Date) {
        let data: Data
        do {
            data = try RuntimeDurableFile.read(url, maximumBytes: 4096, ownerUID: ownerUID)
        } catch  where ownerUID != getuid() {
            data = try RuntimeDurableFile.read(url, maximumBytes: 4096)
        }
        let record = try JSONDecoder().decode(PendingRuntimeOperation.self, from: data)
        if let createdAt = record.createdAt { return (record, createdAt) }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw MicropodError.message("Receipt time is unavailable") }
        return (
            record,
            Date(
                timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec)
                    / 1_000_000_000)
        )
    }
}
