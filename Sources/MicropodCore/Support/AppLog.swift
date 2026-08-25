import Foundation

/// Ring-buffer logger with dual output (memory + file), per the build-macos
/// skill's pattern. Truncates the file on launch.
@Observable
@MainActor
public final class AppLog {
    public static let shared = AppLog()

    public struct Entry: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let timestamp: Date
        public let category: String
        public let message: String
        public let level: Level

        public enum Level: Sendable, Equatable {
            case info, warning, error
        }
    }

    public private(set) var entries: [Entry] = []
    private let maxEntries = 500
    private let fileHandle: FileHandle?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Micropod", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("micropod.log")
        let handle = try? FileHandle(forWritingTo: fileURL)
        if handle == nil {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        self.fileHandle = try? FileHandle(forWritingTo: fileURL)
        try? self.fileHandle?.truncate(atOffset: 0)
    }

    public func log(_ category: String, _ message: String, level: Entry.Level = .info) {
        let entry = Entry(id: UUID(), timestamp: Date(), category: category, message: message, level: level)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        if let data = "[\(ISO8601DateFormatter().string(from: entry.timestamp))] [\(category)] \(message)\n"
            .data(using: .utf8)
        {
            try? fileHandle?.write(contentsOf: data)
        }
        if level == .error {
            NSLog("[Micropod] [\(category)] %@", message)
        }
    }

    public func error(_ category: String, _ message: String) {
        log(category, message, level: .error)
    }

    public func warning(_ category: String, _ message: String) {
        log(category, message, level: .warning)
    }
}

public enum ByteFormat {
    /// "13.2 GB" style formatting for byte counts.
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func string(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
