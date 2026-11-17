import Foundation
import MicropodCore

/// The runtime's default init image, the `vminit.image` property. No XPC
/// route serves it, so it is read through `container system property list`
/// and kept for a minute: the init image guard reads it on every create
/// that asks for an override. A failed read is not kept, so the next create
/// tries again.
public actor RuntimeDefaultInitImage {
    private let read: @Sendable () async throws -> String?
    private let ttl: Duration
    private var cached: (value: String, at: ContinuousClock.Instant)?

    public init(ttl: Duration = .seconds(60), read: @escaping @Sendable () async throws -> String?) {
        self.ttl = ttl
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
        guard let value = try? await read() else { return nil }
        cached = (value, now)
        return value
    }
}
