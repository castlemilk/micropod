import Foundation
import SQLite3

/// Persistent metrics history behind the dashboard graphs and
/// `GetMetricsHistory`: one SQLite file (`~/.micropod/metrics.sqlite`, WAL),
/// rolled up as samples arrive and pruned by age — graphs open with history
/// instead of starting empty, and the file stays small.
///
/// Every sample lands in three tiers at once — 10 s buckets kept 3 h, 1 min
/// buckets kept 48 h, 15 min buckets kept 30 days — each bucket holding the
/// sum, count and maximum of every metric, so a query returns averages and
/// peaks at the resolution its range needs. Samples that share a bucket
/// average out, so two recorders (a dev build beside the app) are harmless.
///
/// Series are keyed by kind + target (a container id, a machine name, or
/// `system` for the all-containers aggregate). Deleting a container or
/// machine deletes its series (``remove(_:_:)``), and ``retain(_:_:)``
/// drops series whose targets vanished behind micropod's back.
public final class MetricsStore: @unchecked Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case system, container, machine
    }

    /// One observation; rates are per second.
    public struct Sample: Sendable, Equatable {
        public var cpuPercent: Double
        public var memoryUsedBytes: Double
        public var memoryLimitBytes: Double
        public var networkRxRate: Double
        public var networkTxRate: Double
        public var blockReadRate: Double
        public var blockWriteRate: Double

        public init(
            cpuPercent: Double = 0, memoryUsedBytes: Double = 0, memoryLimitBytes: Double = 0,
            networkRxRate: Double = 0, networkTxRate: Double = 0, blockReadRate: Double = 0, blockWriteRate: Double = 0
        ) {
            self.cpuPercent = cpuPercent
            self.memoryUsedBytes = memoryUsedBytes
            self.memoryLimitBytes = memoryLimitBytes
            self.networkRxRate = networkRxRate
            self.networkTxRate = networkTxRate
            self.blockReadRate = blockReadRate
            self.blockWriteRate = blockWriteRate
        }

        var values: [Double] {
            [
                cpuPercent, memoryUsedBytes, memoryLimitBytes, networkRxRate, networkTxRate, blockReadRate,
                blockWriteRate,
            ]
        }

        init(_ values: [Double]) {
            self.init(
                cpuPercent: values[0], memoryUsedBytes: values[1], memoryLimitBytes: values[2],
                networkRxRate: values[3], networkTxRate: values[4], blockReadRate: values[5],
                blockWriteRate: values[6])
        }
    }

    /// One bucket: the average and the peak of each metric.
    public struct Point: Sendable, Equatable {
        public var timestamp: Date
        public var average: Sample
        public var peak: Sample
    }

    public struct Tier: Sendable {
        public let bucket: Int64
        public let retention: Int64
    }

    public static let tiers = [
        Tier(bucket: 10, retention: 3 * 3600),
        Tier(bucket: 60, retention: 48 * 3600),
        Tier(bucket: 900, retention: 30 * 86400),
    ]

    public static let defaultURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".micropod/metrics.sqlite")

    /// The process-wide store at ``defaultURL``; nil if it can't be opened.
    public static let shared: MetricsStore? = try? MetricsStore(url: defaultURL)

    private static let columns = ["cpu", "mem", "mem_limit", "rx", "tx", "blk_r", "blk_w"]

    private var db: OpaquePointer?
    private let lock = NSLock()
    private var lastPrune: Date = .distantPast

    public init(url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Owner-only from the start: SQLite gives the -wal/-shm files the
        // database file's mode.
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        for file in [url.path, url.path + "-wal", url.path + "-shm"] where fm.fileExists(atPath: file) {
            chmod(file, 0o600)
        }
        guard
            sqlite3_open_v2(
                url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK
        else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(db)
            throw MicropodError.message("opening \(url.path): \(message)")
        }
        sqlite3_busy_timeout(db, 2000)
        let sums = Self.columns.map { "\($0) REAL NOT NULL, \($0)_max REAL NOT NULL" }.joined(separator: ", ")
        try exec(
            """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS series (
              id INTEGER PRIMARY KEY,
              kind TEXT NOT NULL,
              target TEXT NOT NULL,
              last_seen INTEGER NOT NULL,
              UNIQUE(kind, target)
            );
            CREATE TABLE IF NOT EXISTS points (
              series INTEGER NOT NULL,
              tier INTEGER NOT NULL,
              ts INTEGER NOT NULL,
              n INTEGER NOT NULL,
              \(sums),
              PRIMARY KEY (series, tier, ts)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS points_age ON points (tier, ts);
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: Writing

    /// Records one observation per series, all at `date`, in one transaction.
    public func record(_ batch: [(kind: Kind, target: String, sample: Sample)], at date: Date = Date()) {
        guard !batch.isEmpty else { return }
        let now = Int64(date.timeIntervalSince1970)
        let assignments = Self.columns.map {
            "\($0) = \($0) + excluded.\($0), \($0)_max = max(\($0)_max, excluded.\($0)_max)"
        }.joined(separator: ", ")
        let placeholders = Array(repeating: "?, ?", count: Self.columns.count).joined(separator: ", ")
        lock.withLock {
            guard (try? exec("BEGIN IMMEDIATE")) != nil else { return }
            var ok = true
            for entry in batch {
                guard let series = seriesID(entry.kind, entry.target, lastSeen: now) else {
                    ok = false
                    break
                }
                for (index, tier) in Self.tiers.enumerated() {
                    let bucket = now - now % tier.bucket
                    ok =
                        ok
                        && run(
                            """
                            INSERT INTO points VALUES (?, ?, ?, 1, \(placeholders))
                            ON CONFLICT(series, tier, ts) DO UPDATE SET n = n + 1, \(assignments)
                            """,
                            [.int(series), .int(Int64(index)), .int(bucket)]
                                + entry.sample.values.flatMap { [.double($0), .double($0)] })
                }
            }
            _ = try? exec(ok ? "COMMIT" : "ROLLBACK")
        }
        if date.timeIntervalSince(lastPrune) > 300 {
            lastPrune = date
            prune(now: date)
        }
    }

    /// Deletes a series and all its points (a container or machine was
    /// deleted).
    public func remove(_ kind: Kind, _ target: String) {
        lock.withLock {
            _ = run(
                "DELETE FROM points WHERE series IN (SELECT id FROM series WHERE kind = ? AND target = ?)",
                [.text(kind.rawValue), .text(target)])
            _ = run("DELETE FROM series WHERE kind = ? AND target = ?", [.text(kind.rawValue), .text(target)])
        }
    }

    /// Deletes every `kind` series whose target isn't in `targets` — things
    /// deleted outside micropod (another CLI, a CI job).
    public func retain(_ kind: Kind, _ targets: Set<String>) {
        for target in self.targets(kind) where !targets.contains(target) {
            remove(kind, target)
        }
    }

    /// Drops points past each tier's retention and series left empty.
    public func prune(now: Date = Date()) {
        let now = Int64(now.timeIntervalSince1970)
        lock.withLock {
            for (index, tier) in Self.tiers.enumerated() {
                _ = run(
                    "DELETE FROM points WHERE tier = ? AND ts < ?", [.int(Int64(index)), .int(now - tier.retention)])
            }
            _ = run("DELETE FROM series WHERE id NOT IN (SELECT DISTINCT series FROM points)", [])
        }
    }

    // MARK: Reading

    /// The tier a query over `range` reads: the finest that still covers it.
    public static func tier(for range: TimeInterval) -> Int {
        tiers.firstIndex { TimeInterval($0.retention) >= range } ?? tiers.count - 1
    }

    /// Points for the last `range` seconds, oldest first, at the finest
    /// resolution that covers the range.
    public func history(_ kind: Kind, _ target: String, range: TimeInterval, now: Date = Date())
        -> (resolution: Int64, points: [Point])
    {
        let index = Self.tier(for: range)
        let since = Int64(now.addingTimeInterval(-range).timeIntervalSince1970)
        let selected = Self.columns.map { "\($0), \($0)_max" }.joined(separator: ", ")
        let rows: [[Double]] = lock.withLock {
            query(
                """
                SELECT p.ts, p.n, \(selected) FROM points p JOIN series s ON s.id = p.series
                WHERE s.kind = ? AND s.target = ? AND p.tier = ? AND p.ts >= ? ORDER BY p.ts
                """,
                [.text(kind.rawValue), .text(target), .int(Int64(index)), .int(since)])
        }
        let points = rows.map { row -> Point in
            let n = max(row[1], 1)
            let pairs = stride(from: 2, to: row.count, by: 2).map { (row[$0] / n, row[$0 + 1]) }
            return Point(
                timestamp: Date(timeIntervalSince1970: row[0]),
                average: Sample(pairs.map(\.0)), peak: Sample(pairs.map(\.1)))
        }
        return (Self.tiers[index].bucket, points)
    }

    /// Targets with history of a kind.
    public func targets(_ kind: Kind) -> [String] {
        lock.withLock {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT target FROM series WHERE kind = ?", -1, &statement, nil) == SQLITE_OK
            else { return [] }
            defer { sqlite3_finalize(statement) }
            bind(statement, [.text(kind.rawValue)])
            var targets: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                targets.append(String(cString: sqlite3_column_text(statement, 0)))
            }
            return targets
        }
    }

    // MARK: SQLite

    private enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw MicropodError.message("metrics store: \(message)")
        }
    }

    /// Runs one statement; false when it fails.
    private func run(_ sql: String, _ values: [Value]) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func query(_ sql: String, _ values: [Value]) -> [[Double]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        var rows: [[Double]] = []
        let count = sqlite3_column_count(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<count).map { sqlite3_column_double(statement, $0) })
        }
        return rows
    }

    /// The series id for kind + target, created on first use.
    private func seriesID(_ kind: Kind, _ target: String, lastSeen: Int64) -> Int64? {
        var statement: OpaquePointer?
        let sql = """
            INSERT INTO series (kind, target, last_seen) VALUES (?, ?, ?)
            ON CONFLICT(kind, target) DO UPDATE SET last_seen = excluded.last_seen RETURNING id
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, [.text(kind.rawValue), .text(target), .int(lastSeen)])
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ statement: OpaquePointer?, _ values: [Value]) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, position, v)
            case .double(let v): sqlite3_bind_double(statement, position, v)
            case .text(let v): sqlite3_bind_text(statement, position, v, -1, Self.transient)
            }
        }
    }
}

/// Turns stats snapshots (cumulative byte counters) into metrics samples
/// (per-second rates) and records them: the per-container series plus the
/// `system` aggregate.
public final class MetricsRecorder: @unchecked Sendable {
    private let store: MetricsStore
    private let lock = NSLock()
    private var counters: [String: (at: Date, rx: UInt64, tx: UInt64, read: UInt64, write: UInt64)] = [:]
    private var lastReconcile: Date = .distantPast

    public init(store: MetricsStore) { self.store = store }

    /// Records every container in `snapshot`, and the aggregate.
    public func record(_ snapshot: Micropod_V1_StatsSnapshot, at date: Date = Date()) {
        var batch: [(kind: MetricsStore.Kind, target: String, sample: MetricsStore.Sample)] = []
        var total = MetricsStore.Sample()
        lock.withLock {
            var seen: [String: (at: Date, rx: UInt64, tx: UInt64, read: UInt64, write: UInt64)] = [:]
            for stats in snapshot.containers {
                let now = (
                    at: date, rx: stats.networkRxBytes, tx: stats.networkTxBytes, read: stats.blockReadBytes,
                    write: stats.blockWriteBytes
                )
                var sample = MetricsStore.Sample(
                    cpuPercent: stats.cpuPercent, memoryUsedBytes: Double(stats.memoryUsedBytes),
                    memoryLimitBytes: Double(stats.memoryLimitBytes))
                if let previous = counters[stats.id] {
                    let seconds = max(date.timeIntervalSince(previous.at), 0.001)
                    // A counter that went backwards was reset (a restart): no rate.
                    func rate(_ a: UInt64, _ b: UInt64) -> Double { a >= b ? Double(a - b) / seconds : 0 }
                    sample.networkRxRate = rate(now.rx, previous.rx)
                    sample.networkTxRate = rate(now.tx, previous.tx)
                    sample.blockReadRate = rate(now.read, previous.read)
                    sample.blockWriteRate = rate(now.write, previous.write)
                }
                seen[stats.id] = now
                batch.append((.container, stats.id, sample))
                for (i, value) in sample.values.enumerated() {
                    var totals = total.values
                    totals[i] += value
                    total = MetricsStore.Sample(totals)
                }
            }
            counters = seen
        }
        batch.append((.system, "all", total))
        store.record(batch, at: date)
    }

    /// Records one machine's sample.
    public func recordMachine(_ name: String, _ sample: MetricsStore.Sample, at date: Date = Date()) {
        store.record([(.machine, name, sample)], at: date)
    }

    /// Drops series for containers and machines that no longer exist (at
    /// most every few minutes — lists can be momentarily partial).
    public func reconcile(containers: Set<String>, machines: Set<String>?, at date: Date = Date()) {
        guard date.timeIntervalSince(lastReconcile) > 120 else { return }
        lastReconcile = date
        store.retain(.container, containers)
        if let machines { store.retain(.machine, machines) }
    }
}

extension MetricsStore {
    /// "15m", "1h", "24h", "7d", or plain seconds → seconds.
    public static func parseRange(_ text: String) -> TimeInterval? {
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        if let unit = text.last.flatMap({ units[$0] }), let n = Double(text.dropLast()), n > 0 { return n * unit }
        if let n = Double(text), n > 0 { return n }
        return nil
    }

    /// A compact text summary of a history: per metric the peak, average and
    /// latest value, plus a sparkline — what MCP and the CLI print.
    public static func summary(
        _ history: (resolution: Int64, points: [Point]), title: String, range: TimeInterval
    ) -> String {
        let points = history.points
        guard let last = points.last else { return "\(title): no history in the last \(rangeText(range))" }
        var lines = [
            "\(title): \(points.count) points at \(history.resolution)s resolution over the last \(rangeText(range))"
        ]
        func row(
            _ name: String, _ average: (Sample) -> Double, _ peak: (Sample) -> Double, _ format: (Double) -> String
        ) {
            let averages = points.map { average($0.average) }
            let mean = averages.reduce(0, +) / Double(averages.count)
            let max = points.map { peak($0.peak) }.max() ?? 0
            lines.append(
                "\(name.padding(toLength: 8, withPad: " ", startingAt: 0)) peak \(format(max))  avg \(format(mean))  "
                    + "now \(format(average(last.average)))  \(sparkline(averages))")
        }
        let percent = { (v: Double) in String(format: "%.1f%%", v) }
        let bytes = { (v: Double) in ByteFormat.string(UInt64(Swift.max(0, v))) }
        let rate = { (v: Double) in ByteFormat.string(UInt64(Swift.max(0, v))) + "/s" }
        row("cpu", \.cpuPercent, \.cpuPercent, percent)
        row("memory", \.memoryUsedBytes, \.memoryUsedBytes, bytes)
        row("net rx", \.networkRxRate, \.networkRxRate, rate)
        row("net tx", \.networkTxRate, \.networkTxRate, rate)
        row("disk r", \.blockReadRate, \.blockReadRate, rate)
        row("disk w", \.blockWriteRate, \.blockWriteRate, rate)
        return lines.joined(separator: "\n")
    }

    /// ▁▂▃▅▇ over at most 40 evenly spaced values.
    static func sparkline(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "" }
        let step = Swift.max(1, values.count / 40)
        let sampled = stride(from: 0, to: values.count, by: step).map { values[$0] }
        let lo = sampled.min() ?? 0
        let hi = sampled.max() ?? 0
        let bars = Array("▁▂▃▄▅▆▇█")
        return String(
            sampled.map { hi > lo ? bars[Int(((($0 - lo) / (hi - lo)) * 7).rounded())] : bars[0] })
    }

    static func rangeText(_ seconds: TimeInterval) -> String {
        if seconds >= 86400, seconds.truncatingRemainder(dividingBy: 86400) == 0 { return "\(Int(seconds / 86400))d" }
        if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(seconds / 3600))h" }
        if seconds >= 60 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds))s"
    }
}
