import Foundation

/// Docker's prune `filters` query, read the way dockerd reads it — and
/// strictly, because a prune deletes: a filter that cannot be read is a 400,
/// never a prune without it.
///
/// The value is Docker's JSON: `{"label":{"a=b":true},"label!":{"k":true}}`
/// (what the docker CLI and SDKs send) or the legacy
/// `{"label":["a=b"],"label!":["k"]}`. Anything else is invalid, like
/// dockerd's `filters.FromJSON`.
struct PruneFilters: Equatable, Sendable {
    /// `label` values (`key` or `key=value`): a candidate must carry every one.
    var labels: [String] = []
    /// `label!` values, nil when the key is absent: a candidate carrying
    /// every one is kept (`label!` with no values keeps everything, as in
    /// dockerd).
    var excludedLabels: [String]?
    /// `until` (container prune): only candidates created at or before it.
    var until: Date?
    /// `dangling` (volume prune): `false` selects in-use volumes, which a
    /// prune never deletes.
    var dangling: Bool?

    /// dockerd's container prune filters.
    static let containerKeys: Set<String> = ["label", "label!", "until"]
    /// dockerd's volume prune filters, plus `dangling`. `all` (API ≥ 1.42:
    /// named volumes too, not only anonymous ones) is accepted and changes
    /// nothing: the runtime's volumes are all named, and the shim has always
    /// treated every unused one as a candidate.
    static let volumeKeys: Set<String> = ["label", "label!", "all", "dangling"]

    init() {}

    /// Parses `raw` (the `filters` query value; nil or empty is no filter),
    /// admitting only `accepted` keys.
    init(json raw: String?, accepted: Set<String>, now: Date = Date()) throws {
        guard let raw, !raw.isEmpty else { return }
        let data = Data(raw.utf8)
        let fields: [String: [String]]
        if let current = try? JSONDecoder().decode([String: [String: Bool]].self, from: data) {
            fields = current.mapValues { $0.keys.sorted() }
        } else if let legacy = try? JSONDecoder().decode([String: [String]].self, from: data) {
            fields = legacy
        } else {
            throw ShimError.badRequest("invalid filters: \(raw)")
        }
        for key in fields.keys.sorted() where !accepted.contains(key) {
            throw ShimError.badRequest("invalid filter '\(key)'")
        }
        labels = fields["label"] ?? []
        excludedLabels = fields["label!"]
        if let values = fields["until"] {
            guard values.count == 1 else {
                throw ShimError.badRequest("only one until filter is allowed, got \(values.count)")
            }
            guard let date = DockerTimestamp.parse(values[0], now: now) else {
                throw ShimError.badRequest("failed to parse value as time or duration: \"\(values[0])\"")
            }
            until = date
        }
        if let values = fields["all"] {
            _ = try Self.bool(values, key: "all")
        }
        if let values = fields["dangling"] {
            dangling = try Self.bool(values, key: "dangling")
        }
    }

    /// Whether a candidate with `labels` passes `label` and `label!`
    /// (dockerd's `matchLabels`).
    func admits(labels candidate: [String: String]) -> Bool {
        guard Self.carriesAll(labels, in: candidate) else { return false }
        if let excludedLabels, Self.carriesAll(excludedLabels, in: candidate) { return false }
        return true
    }

    /// Whether a candidate created at `created` passes `until`. A creation
    /// date that cannot be read cannot be shown to be old enough: kept.
    func admits(created: Date?) -> Bool {
        guard let until else { return true }
        guard let created else { return false }
        return created <= until
    }

    /// dockerd's `MatchKVList`: every `key` / `key=value` is present in
    /// `labels` — vacuously for no filters, never for no labels.
    static func carriesAll(_ filters: [String], in labels: [String: String]) -> Bool {
        if filters.isEmpty { return true }
        if labels.isEmpty { return false }
        for filter in filters {
            let parts = filter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let actual = labels[String(parts[0])] else { return false }
            if parts.count == 2, actual != String(parts[1]) { return false }
        }
        return true
    }

    /// Go's `strconv.ParseBool` over the single value a boolean filter takes.
    private static func bool(_ values: [String], key: String) throws -> Bool {
        guard values.count == 1 else {
            throw ShimError.badRequest("filter '\(key)' takes one value, got \(values.count)")
        }
        switch values[0] {
        case "1", "t", "T", "true", "TRUE", "True": return true
        case "0", "f", "F", "false", "FALSE", "False": return false
        default: throw ShimError.badRequest("invalid value for filter '\(key)': \(values[0])")
        }
    }
}

/// The time values Docker filters take (`until`, `since`), as the docker
/// CLI's `timetypes.GetTimestamp` reads them: a Go duration back from now
/// (`24h`, `1h30m`), an RFC 3339 date-time with a zone (`2026-09-26T10:00:00Z`,
/// `…+10:00`, fractional seconds allowed), a zoneless date or date-time in
/// local time (`2026-09-26`, `2026-09-26T10`, `…T10:00`, `…T10:00:00`), or
/// Unix seconds (`1790000000`, `1790000000.5`).
enum DockerTimestamp {
    static func parse(_ value: String, now: Date) -> Date? {
        if value != "0", let seconds = goDuration(value) {
            return now.addingTimeInterval(-seconds)
        }
        if let date = dateTime(value) { return date }
        // A dash that did not parse as a date is a malformed date, not a
        // Unix time.
        if value.contains("-") { return nil }
        return unixSeconds(value)
    }

    /// Seconds in a Go `time.ParseDuration` string: an optional sign, then
    /// one or more decimal numbers each followed by a unit.
    static func goDuration(_ text: String) -> TimeInterval? {
        var rest = Substring(text)
        var sign = 1.0
        if let first = rest.first, first == "-" || first == "+" {
            sign = first == "-" ? -1 : 1
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty else { return nil }
        var total = 0.0
        while !rest.isEmpty {
            let number = rest.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
            guard !number.isEmpty, number != ".", let amount = Double(number) else { return nil }
            rest = rest.dropFirst(number.count)
            let unit = rest.prefix { !($0.isASCII && ($0.isNumber || $0 == ".")) }
            guard let scale = durationUnits[String(unit)] else { return nil }
            rest = rest.dropFirst(unit.count)
            total += amount * scale
        }
        return sign * total
    }

    private static let durationUnits: [String: TimeInterval] = [
        "ns": 1e-9, "us": 1e-6, "µs": 1e-6, "μs": 1e-6, "ms": 1e-3, "s": 1, "m": 60, "h": 3600,
    ]

    private static func dateTime(_ value: String) -> Date? {
        let zoned = value.contains { "zZ+".contains($0) } || value.filter { $0 == "-" }.count == 3
        if zoned {
            for options: ISO8601DateFormatter.Options in [
                [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
            ] {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = options
                if let date = formatter.date(from: value) { return date }
            }
            return formatted(value, layouts: ["yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HHXXXXX", "yyyy-MM-ddXXXXX"])
        }
        // Local time; a fraction of a second is split off (DateFormatter
        // reads a fixed number of fractional digits).
        var whole = value
        var fraction = 0.0
        if let dot = value.firstIndex(of: ".") {
            let digits = value[value.index(after: dot)...]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let parsed = Double("0." + digits) else {
                return nil
            }
            whole = String(value[..<dot])
            fraction = parsed
        }
        let layouts = [
            "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH", "yyyy-MM-dd",
        ]
        return formatted(whole, layouts: layouts)?.addingTimeInterval(fraction)
    }

    private static func formatted(_ value: String, layouts: [String]) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.isLenient = false
        for layout in layouts {
            formatter.dateFormat = layout
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func unixSeconds(_ value: String) -> Date? {
        let parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = parts.first, !whole.isEmpty, whole.allSatisfy(\.isNumber),
            parts.count == 1 || (!parts[1].isEmpty && parts[1].count <= 9 && parts[1].allSatisfy(\.isNumber)),
            let seconds = Double(value)
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
