import Foundation

/// Covers whole desktop operations, including the intervals between their
/// individual API calls. Daemons never opt in to DesktopActivity.
public struct DesktopContainerService: ContainerServing {
    private let base: any ContainerServing
    public init(_ base: any ContainerServing) { self.base = base }
    public func list() async throws -> [Micropod_V1_Container] { try await base.list() }
    public func inspect(_ id: String) async throws -> Data { try await base.inspect(id) }
    private func operation<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        let claim = try DesktopActivity.shared.claim()
        defer { withExtendedLifetime(claim) {} }
        return try await body()
    }
    public func create(_ request: ContainerRunRequest) async throws -> String {
        try await operation { try await base.create(request) }
    }
    public func run(_ request: ContainerRunRequest) async throws -> String {
        try await operation { try await base.run(request) }
    }
    public func exec(_ request: ContainerExecRequest) async throws -> String {
        try await operation { try await base.exec(request) }
    }
    public func execDetailed(_ request: ContainerExecRequest) async throws -> ContainerExecResult {
        try await operation { try await base.execDetailed(request) }
    }
    public func start(_ id: String) async throws { try await operation { try await base.start(id) } }
    public func stop(_ id: String, timeout: Int) async throws {
        try await operation { try await base.stop(id, timeout: timeout) }
    }
    public func restart(_ id: String) async throws { try await operation { try await base.restart(id) } }
    public func stopAll() async throws { try await operation { try await base.stopAll() } }
    public func kill(_ id: String, signal: String) async throws {
        try await operation { try await base.kill(id, signal: signal) }
    }
    public func delete(_ id: String, force: Bool) async throws {
        try await operation { try await base.delete(id, force: force) }
    }
    public func deleteAll(force: Bool) async throws { try await operation { try await base.deleteAll(force: force) } }
    public func prune() async throws -> String { try await operation { try await base.prune() } }
    public func export(_ id: String, to path: String) async throws {
        try await operation { try await base.export(id, to: path) }
    }
    public func copy(from: String, to: String) async throws {
        try await operation { try await base.copy(from: from, to: to) }
    }
}
