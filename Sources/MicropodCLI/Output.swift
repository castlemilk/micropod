import Foundation
import SwiftProtobuf

#if canImport(Darwin)
    import Darwin
#endif

enum Ansi {
    static let reset = "\u{1b}[0m"
    static let bold = "\u{1b}[1m"
    static let dim = "\u{1b}[2m"
    static let red = "\u{1b}[31m"
    static let green = "\u{1b}[32m"
    static let yellow = "\u{1b}[33m"
    static let blue = "\u{1b}[34m"

    nonisolated(unsafe) static var enabled = {
        #if canImport(Darwin)
            isatty(STDOUT_FILENO) == 1
        #else
            false
        #endif
    }()

    static func paint(_ text: String, _ code: String) -> String {
        enabled ? "\(code)\(text)\(reset)" : text
    }

    static func state(_ state: String) -> String {
        switch state.lowercased() {
        case "running": return paint(state, green)
        case "stopped", "exited": return paint(state, red)
        case "created": return paint(state, blue)
        default: return paint(state, yellow)
        }
    }

    static func ok(_ text: String) -> String { paint("✓ \(text)", green) }
    static func warn(_ text: String) -> String { paint("⚠ \(text)", yellow) }
    static func fail(_ text: String) -> String { paint("✗ \(text)", red) }
}

func renderTable(headers: [String], rows: [[String]]) -> String {
    guard !rows.isEmpty else { return "" }
    var widths = headers.map { $0.count }
    for row in rows {
        for (i, cell) in row.enumerated() where i < widths.count {
            widths[i] = max(widths[i], cell.count)
        }
    }
    let pad: (String, Int) -> String = { text, width in
        text + String(repeating: " ", count: max(0, width - text.count))
    }
    var lines = [headers.enumerated().map { pad($1, widths[$0]) }.joined(separator: "  ")]
    lines.append(widths.map { String(repeating: "─", count: $0) }.joined(separator: "  "))
    for row in rows {
        lines.append(row.enumerated().map { pad($1, widths[$0]) }.joined(separator: "  "))
    }
    return lines.joined(separator: "\n")
}

func relativeAge(from iso: String, now: Date = Date()) -> String {
    let formatters = [
        { () -> ISO8601DateFormatter in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }(),
        ISO8601DateFormatter(),
    ]
    for formatter in formatters {
        if let date = formatter.date(from: iso) {
            return shortAge(from: date, now: now)
        }
    }
    return "—"
}

private func shortAge(from date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return Int(seconds) == 0 ? "now" : "\(Int(seconds))s ago"
    case ..<3600: return "\(Int(seconds / 60))m ago"
    case ..<86400:
        let hours = Int(seconds / 3600)
        return "\(hours)h\(Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60))m ago"
    default: return "\(Int(seconds / 86400))d ago"
    }
}

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

func emitJSON<T: SwiftProtobuf.Message>(_ messages: [T]) {
    let joined = messages.compactMap { (try? $0.jsonUTF8Data()) }
        .compactMap { String(data: $0, encoding: .utf8) }
        .joined(separator: ",")
    print("[\(joined)]")
}

func errorMessage(_ error: Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
        return description
    }
    return String(describing: error)
}
