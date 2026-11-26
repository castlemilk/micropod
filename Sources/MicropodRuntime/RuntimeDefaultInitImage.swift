import Foundation
import MicropodCore

/// The runtime's default init image, the `vminit.image` property. No XPC
/// route serves it, so it is read through `container system property list`
/// and kept for a minute: the init image guard reads it on every create
/// that asks for an override. A failed (or empty) read is kept for
/// `failureTTL`, zero by default so the next create tries again; the API's
/// Ping keeps one for 30 s, so a stopped runtime is not asked on every call.
/// Concurrent callers share one read.
public actor RuntimeDefaultInitImage {
    private let read: @Sendable () async throws -> String?
    private let ttl: Duration
    private let failureTTL: Duration
    private var cached: (value: String, at: ContinuousClock.Instant)?
    private var failedAt: ContinuousClock.Instant?
    private var reading: Task<String?, Never>?

    public init(
        ttl: Duration = .seconds(60), failureTTL: Duration = .zero,
        read: @escaping @Sendable () async throws -> String?
    ) {
        self.ttl = ttl
        self.failureTTL = failureTTL
        self.read = read
    }

    /// Reads the property through the `container` CLI.
    public static func reading(_ machine: MachineService) -> RuntimeDefaultInitImage {
        RuntimeDefaultInitImage { vminitImage(in: try await machine.properties()) }
    }

    /// `vminit.image` from a property listing, nil when absent or empty.
    public static func vminitImage(in properties: SystemPropertyListResponse) -> String? {
        guard case .string(let image)? = properties["vminit"]?["image"] else { return nil }
        let trimmed = image.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The kept value while it is fresh, without reading the property.
    public func peek() -> String? {
        guard let cached, ContinuousClock.now - cached.at < ttl else { return nil }
        return cached.value
    }

    public func value() async -> String? {
        let now = ContinuousClock.now
        if let cached, now - cached.at < ttl { return cached.value }
        if let failedAt, now - failedAt < failureTTL { return nil }
        if let reading { return await reading.value }
        let read = self.read
        let task = Task { try? await read() }
        reading = task
        let value = await task.value
        reading = nil
        if let value {
            cached = (value, now)
            failedAt = nil
        } else {
            failedAt = now
        }
        return value
    }
}
