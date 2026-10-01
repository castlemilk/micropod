import Foundation

/// Stored chunk bytes are file payload sizes, not an estimate of APFS
/// physical space. View sizes must not be added to this total.
public struct SharedCacheSnapshot: Codable, Sendable {
    public let cacheRoot: String
    public let measuredAt: Date
    public let storedBytes: UInt64
    public let capBytes: UInt64
    public let chunkCount: Int
    public let activeMounts: [MountInfo]
    public let keepEnabled: Bool
    public let overCap: Bool
    public let retentionWarning: String?

    public init(
        cacheRoot: String, measuredAt: Date, storedBytes: UInt64, capBytes: UInt64,
        chunkCount: Int, activeMounts: [MountInfo], keepEnabled: Bool, overCap: Bool,
        retentionWarning: String? = nil
    ) {
        self.cacheRoot = cacheRoot
        self.measuredAt = measuredAt
        self.storedBytes = storedBytes
        self.capBytes = capBytes
        self.chunkCount = chunkCount
        self.activeMounts = activeMounts
        self.keepEnabled = keepEnabled
        self.overCap = overCap
        self.retentionWarning = retentionWarning
    }
}

/// A preview produced by the owning daemon. The token restricts cleanup
/// to chunks present when reviewed; newer cache data is never included.
public struct SharedCacheCleanupReview: Codable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let chunkCount: Int
    public let storedBytes: UInt64
    public let protectedChunkCount: Int
    public let blockedReason: String?
}

extension SharedFSClient {
    /// Defaults let older/custom clients remain compatible. The desktop
    /// treats these failures as unavailable capabilities, never as zeros.
    public func cacheSnapshot() async throws -> SharedCacheSnapshot {
        throw SharedFSError.invalidResponse("Cache management is unavailable on this daemon.")
    }

    public func reviewCacheCleanup() async throws -> SharedCacheCleanupReview {
        throw SharedFSError.invalidResponse("Cache cleanup review is unavailable on this daemon.")
    }

    public func cleanReviewedCache(id: String) async throws -> GCResult {
        throw SharedFSError.invalidResponse("Reviewed cleanup is unavailable on this daemon.")
    }

    public func setCacheKeepEnabled(_ enabled: Bool) async throws {
        throw SharedFSError.invalidResponse("Cache retention is unavailable on this daemon.")
    }
}

extension SharedFSError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sourceUnreadable(let url): "Cannot read the shared source at \(url.path)."
        case .clonefileUnavailable: "The filesystem could not clone the shared data."
        case .daemonUnavailable: "The shared cache agent is unavailable."
        case .invalidResponse(let detail): detail
        }
    }
}
