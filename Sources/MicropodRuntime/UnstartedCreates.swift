import Foundation

/// Container ids this process created natively that no start of this
/// process has run yet: the one place a failed start can learn that its
/// container existed.
///
/// container-apiserver keeps no tombstones. A start whose container is gone
/// gets `notFound: container with ID <id> not found` whether the id was
/// deleted a moment after its create or never created at all, so a start
/// says its container was deleted before it could start only when the
/// create is known to have happened: `run` created it itself, or `create`
/// recorded the id here.
///
/// An id leaves once a start of it has run (whatever the outcome) and on
/// `delete`/`deleteAll`/`prune`. A create that is never started or deleted
/// through this process would stay, so the oldest record is dropped once
/// `capacity` is reached; a dropped id only loses the claim, never the
/// start. Process-wide, like `InFlightCreates`, so a backend hot-swap
/// between a create and its start keeps the record.
actor UnstartedCreates {
    static let shared = UnstartedCreates()

    let capacity: Int
    /// id → when it was recorded, in record order.
    private var records: [String: UInt64] = [:]
    private var sequence: UInt64 = 0

    init(capacity: Int = 4096) {
        self.capacity = max(1, capacity)
    }

    /// Records a create of `id` that just succeeded; recording it again
    /// makes it the newest record.
    func record(_ id: String) {
        sequence += 1
        records[id] = sequence
        if records.count > capacity, let oldest = records.min(by: { $0.value < $1.value })?.key {
            records[oldest] = nil
        }
    }

    func contains(_ id: String) -> Bool {
        records[id] != nil
    }

    func remove(_ id: String) {
        records[id] = nil
    }
}
