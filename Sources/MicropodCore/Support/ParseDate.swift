import Foundation

/// Parses the runtime's ISO8601 timestamp (with optional fractional seconds).
/// Formatters are cached: they are expensive to allocate and this sits on the
/// table sort/row-render hot path.
public func parseDate(_ string: String) -> Date? {
    guard !string.isEmpty else { return nil }
    if let date = ParseDateFormatters.fractional.date(from: string) { return date }
    return ParseDateFormatters.plain.date(from: string)
}

enum ParseDateFormatters {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) static let plain = ISO8601DateFormatter()
}
